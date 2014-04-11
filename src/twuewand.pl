#!/usr/bin/perl -w

########################################################################
# twuewand, a truerand algorithm for generating entropy
# Copyright (C) 2012 Ryan Finnie <ryan@finnie.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.
########################################################################

# Intended usage:
#   twuewand $(($(cat /proc/sys/kernel/random/poolsize)/8)) | rndaddentropy

my $VERSION = '2.0';
my $EXTRAVERSION = '#EXTRAVERSION#';

use warnings;
use strict;
use Getopt::Long;
use Pod::Usage;
use Time::HiRes qw/alarm time/;
use Module::Load::Conditional qw/can_load/;
# Digest::SHA may be loaded below
# Digest::MD5 may be loaded below
# Crypt::Rijndael may be loaded below

my $versionstring = sprintf('twuewand %s%s',
  $VERSION,
  ($EXTRAVERSION eq ('#'.'EXTRAVERSION'.'#') ? '' : $EXTRAVERSION)
);

my(
  $opt_help,
  $opt_quiet,
  $opt_verbose,
  $opt_interval,
  $opt_bytes,
  $opt_seconds,
  $opt_debias,
  $opt_md5,
  $opt_sha,
  $opt_aes,
);

$opt_interval = 0;
$opt_bytes = 0;
$opt_seconds = 0;
$opt_debias = 1;
$opt_md5 = 1;
$opt_sha = 1;
$opt_aes = 1;

my($optresult) = GetOptions(
  'help|?' => \$opt_help,
  'quiet|q' => \$opt_quiet,
  'verbose|v' => \$opt_verbose,
  'interval|i=f' => \$opt_interval,
  'bytes|b=f' => \$opt_bytes,
  'seconds|s=f' => \$opt_seconds,
  'debias!' => \$opt_debias,
  'md5!' => \$opt_md5,
  'sha!' => \$opt_sha,
  'aes!' => \$opt_aes,
);

if($ARGV[0] && (int($ARGV[0]) > 0)) {
  $opt_bytes = int($ARGV[0]);
}

if(!($opt_bytes || $opt_seconds) || $opt_help || $opt_verbose) {
  print STDERR "$versionstring\n";
  print STDERR "Copyright (C) 2012 Ryan Finnie <ryan\@finnie.org>\n";
  print STDERR "\n";
  if(!($opt_bytes || $opt_seconds) || $opt_help) {
    pod2usage(2);
  }
}

# A digest function object and size of its output.  If debiasing is 
# disabled, no digest will be used, and instead bytes will output one 
# at a time.
my($digestobj);
my($digestsize) = 1;
my($has_hash, $has_sha, $has_md5, $has_aes);
my($outbufflimit) = 16;
if($opt_debias) {
  if($opt_verbose) { print STDERR "Von Neumann debiasing will be performed.\n"; }
  # I originally included a minimum version of 4.3.0 when I was using 
  # SHA512, but, err, I have no idea how I came about that version, 
  # since earlier versions appear to have SHA512 support.  But hey, 
  # 4.3.0 was from 2004, so if you're running Perl modules that old, 
  # you've probably got larger problems.
  if($opt_sha && can_load(modules => {'Digest::SHA' => 4.3.0})) {
    if($opt_verbose) { print STDERR "Digest::SHA will be used for hashing.\n"; }
    require Digest::SHA;
    $has_hash = 1;
    $has_sha = 1;
    $digestobj = \&Digest::SHA::sha256;
    $digestsize = 32;
    $outbufflimit = 32;
    if($opt_aes && can_load(modules => {'Crypt::Rijndael' => undef})) {
      if($opt_verbose) { print STDERR "Crypt::Rijndael (AES) found; Kaminsky debiasing will be performed.\n"; }
      require Crypt::Rijndael;
      $has_aes = 1;
      # Since in Kaminsky debiasing, the raw generated bits are fed to 
      # a hash which is used as a key to encrypt the output data, we 
      # don't want to output the debiased buffer too often.  1024 
      # bytes is a good round number.
      $outbufflimit = 1024;
    }
  } elsif($opt_md5) {
    if($opt_verbose) { print STDERR "Digest::SHA not found; using Digest::MD5 for hashing instead.\n"; }
    require Digest::MD5;
    $has_hash = 1;
    $has_md5 = 1;
    $digestobj = \&Digest::MD5::md5;
    $digestsize = 16;
    $outbufflimit = 16;
  }
} else {
  if($opt_verbose) { print STDERR "Performing no debiasing whatsoever!\n"; }
}

if($opt_verbose) { print STDERR "\n"; }

# Enable adaptive mode if no interval set.
my($opt_adaptive);
if($opt_interval) {
  $opt_adaptive = 0;
} else {
  $opt_adaptive = 1;
  # 4ms becomes the default starting point in adaptive mode.
  $opt_interval = 0.004;
}

# Do not use a smaller interval than CLOCK_REALTIME.
my($min_interval) = Time::HiRes::clock_getres(Time::HiRes::CLOCK_REALTIME());
if($opt_interval < $min_interval) {
  $opt_interval = $min_interval;
}

# Data stored (up to $outbufflimit bytes) before debiasing/outputting
my($outbuff) = "";
# The length of $outbuff
my($outbufflen) = 0;

# Signal handlers
$SIG{ALRM} = "tick";
$SIG{INT} = "sig_int";

# These variables must be global since the alarm handler relies on them
my($statebitint, $outbitscnt, $outbitsint, $lastbitint, $lastbitheld);
my($discardedbitcnt) = 0;

my($rawbitsint, $rawbitscnt, $sha, $shastreamcnt, $shabuff);
if($has_hash && $has_sha && $has_aes) {
  # Raw (non-Von Neumann) bits are used to seed a global SHA256 hash.
  $rawbitscnt = 0;
  $rawbitsint = 0;
  $shastreamcnt = 0;
  $shabuff = '';
  $sha = Digest::SHA->new(256);
}

# Target number of flips per byte (99.90% confidence (Z=3.3), 0.01 max
# error).
my $adaptive_target = 27225;
# Average calculated interval.
my $adaptive_avginterval = 0;

my $started = time();
my $reqbytesi = 0;
while(1) {
  $outbitscnt = 0;
  $outbitsint = 0;
  # Set the alarm
  $statebitint = 0; alarm($opt_interval);

  if($opt_adaptive) {
    # Number of bit flips in the last byte.
    my $adaptive_flipcount = 0;

    # Flip a state bit until a full byte is built.
    # Note: the alarm handler will reset $statebitint to 0 after an output
    # bit is generated.
    while($outbitscnt < 8) {
      $statebitint ^= 1;
      $adaptive_flipcount++;
    }

    # If this is the first sample, seed the average interval with a best
    # guess.
    if($adaptive_avginterval == 0) {
      $adaptive_avginterval = $adaptive_target / ($adaptive_flipcount / $opt_interval);
    } else {
      # Update the average target interval with a modified moving
      # average (MMA)
      $adaptive_avginterval = ($reqbytesi * $adaptive_avginterval + ($adaptive_target / ($adaptive_flipcount / $opt_interval))) / ($reqbytesi + 1);
    }
    $opt_interval = $adaptive_avginterval;

    # If the calculated interval is lower than Time::HiRes's
    # CLOCK_REALTIME, use CLOCK_REALTIME instead.
    if($opt_interval < $min_interval) {
      $opt_interval = $min_interval;
    }
  } else {
    # Flip a state bit until a full byte is built.
    # Note: the alarm handler will reset $statebitint to 0 after an output
    # bit is generated.
    while($outbitscnt < 8) {
      $statebitint ^= 1;
    }
  }

  # Once we have a full byte, add it to the buffer
  $outbuff .= chr($outbitsint);
  $outbufflen++;
  if(!$opt_quiet) {
    if($opt_bytes) {
      printf STDERR "%sGenerated: %d/%d bytes (%3d%%)", chr(13), ($reqbytesi + 1), $opt_bytes, (($reqbytesi + 1) / $opt_bytes * 100);
    } else {
      printf STDERR "%sGenerated: %d bytes", chr(13), ($reqbytesi + 1);
    }
    if($opt_seconds) {
      printf STDERR " (%d/%ds)", (time() - $started), $opt_seconds;
    }
  }

  # If we start to have a lot of data in the output buffer, output the 
  # fully debiased buffer and start again.  We don't want to do this 
  # too often, since each output takes a significant time penalty (SHA 
  # + AES at worst).
  if($outbufflen == $outbufflimit) {
    print process_buffer();    
  }

  $reqbytesi++;
  last if($opt_seconds && (time() >= ($started + $opt_seconds)));
  last if($opt_bytes && ($reqbytesi == $opt_bytes));
}

finalize_run();
exit;

sub finalize_run {
  # If there are any bytes left in the buffer, output the fully debiased 
  # buffer.
  if($outbufflen > 0) {
    print process_buffer();
  }

  if(!$opt_quiet) { print STDERR "\n"; }
  if($opt_verbose && $opt_debias) {
    printf STDERR "Used %d extra bits (%d%%) while debiasing.\n", $discardedbitcnt, $discardedbitcnt / ($reqbytesi * 8 + $discardedbitcnt) * 100;
    if($has_sha && $shastreamcnt) {
      printf STDERR "Seeded %d bytes into the SHA key.\n", $shastreamcnt;
    }
  }
}

sub process_buffer {
  my $out;

  if($has_hash && $has_sha && $has_aes) {
    # Add the SHA byte buffer to the SHA256 stream and generate a 
    # hash.
    if($shabuff) {
      $shastreamcnt += length($shabuff);
      $sha->add($shabuff);
      $shabuff = '';
    }
    my $aeskey = $sha->clone->digest;

    # Encrypt the output buffer with the modified key.
    my $cipher = Crypt::Rijndael->new($aeskey, Crypt::Rijndael::MODE_CTR());
    my $padding = '';
    if($outbufflen % 16) {
      $padding = chr(0) x (16 - ($outbufflen % 16));
    }
    $out = substr($cipher->encrypt($outbuff . $padding), 0, $outbufflen);
  } elsif($has_hash) {
    $out = substr(&$digestobj($outbuff), 0, $outbufflen);
  } else {
    $out = $outbuff;
  }

  $outbuff = "";
  $outbufflen = 0;

  return $out;
}

sub tick {
  # We have a random bit!

  if(!$opt_debias) {
    # If no debiasing is to be performed, don't bother with the Von 
    # Neumann dance.  Instead, add the state bit directly to the 
    # output bits.
    $outbitsint = ($outbitsint << 1) | $statebitint;
    $outbitscnt++;
  } else {
    if($has_hash && $has_sha && $has_aes) {
      # The raw bits (all bits, not just bits which pass Von Neumann) are 
      # only used to seed a SHA256 key.  Every time we have 8 full bits, 
      # put a byte into the SHA stream.
      $rawbitsint = ($rawbitsint << 1) | $statebitint;
      $rawbitscnt++;
      if($rawbitscnt == 8) {
        $shabuff .= chr($rawbitsint);
        $rawbitscnt = 0;
        $rawbitsint = 0;
      }
    }

    # We want to run the input bits through Von Neumann debiasing, so 
    # the last bit is held for analysis.
    if($lastbitheld) {
      if(($lastbitint && $statebitint) || (!$lastbitint && !$statebitint)) {
        # If this bit and the last bit are both 0 or both 1, simply 
        # throw out both bits.
        $discardedbitcnt += 2;
      } else {
        # Otherwise, shift the working byte and add the PREVIOUS bit.  
        # So (0, 1) becomes 0 and (1, 0) becomes 1.
        $outbitsint = ($outbitsint << 1) | $lastbitint;
        $outbitscnt++;
        $discardedbitcnt++;
      }
      # Forget about the last bit.  The next bit to be generated will be 
      # the first part of the pair.
      $lastbitheld = 0;
    } else {
      # If we didn't have a bit held, use the generated bit to as the 
      # last bit.
      $lastbitint = $statebitint;
      $lastbitheld = 1;
    }
  }

  # If we still need more bits for this byte, schedule a new alarm
  if($outbitscnt < 8) {
    $statebitint = 0; alarm($opt_interval);
  }
}

sub sig_int {
  finalize_run();
  exit;
}

__END__

=head1 NAME

twuewand - A truerand algorithm for generating entropy

=head1 SYNOPSIS

B<twuewand> S<[ B<options> ]> I<bytes>

=head1 DESCRIPTION

B<twuewand> is software that creates hardware-generated random data.  
It accomplishes this by exploiting the fact that the CPU clock and the 
RTC (real-time clock) are physically separate, and that time and work 
are not linked.

twuewand schedules a SIGALRM for a short time in the future, then begins 
flipping a bit as fast as possible.  When the alarm is delivered, the 
bit's state is recorded.  Von Neumann debiasing is (by default) 
performed on bit pairs, throwing out matching bit pairs, and using the 
first bit for non-matching bit pairs.  This reduces bias, at the expense 
of wasted bits.

This process is performed multiple times until the number of desired 
bytes have been generated.  The data is then (by default) either run 
through a cryptographic hash digest (default SHA256, but will fall 
back to MD5 if Digest::SHA is not available), or encrypted with a 
hashed key (Kaminsky debiasing) to further debias the data before 
being output.

twuewand is based on the truerand algorithm, by D. P. Mitchell in 
1995.  The output of twuewand may be used for random data directly (as 
long as debiasing is not disabled), but its primary purpose is for 
seeding a PRNG, when a saved PRNG state is not available (on a LiveCD 
or diskless workstation, for example), or when insufficient initial 
entropy is not available (in a virtual machine, for example).  An 
example use in Linux is:

    twuewand $(($(cat /proc/sys/kernel/random/poolsize)/8)) | rndaddentropy

(This example is specific to Linux 2.6 and later.  poolsize in Linux 
2.6 is represented in its, while 2.4 and earlier is bytes.)

B<rndaddentropy> is a helper utility to send data to the RNDADDENTROPY 
ioctl.  This can be dangerous without a good source of entropy (such as 
a hardware key or twuewand with sufficient debiasing); see 
I<rndaddentropy(8)> for details.

You may also send twuewand output to /dev/random or /dev/urandom, but 
this merely "stirs the pot", and does not directly add entropy to the 
pool.

Unless specifically disabled (see below), twuewand will try to use a 
variety of debiasing techniques, The most comprehensive method will be 
chosen, depending on what Perl modules are available.  They include:

=over

Von Neumann simple debiasing.

Kaminsky debiasing, an extension of Von Neumann.  This requires 
Digest::SHA and Crypt::Rijndael (AES).

Output hashing with SHA256 (Digest::SHA).

Output hashing with MD5 (Digest::MD5).

=back

=head1 OPTIONS

=over

=item B<-i> interval (B<--interval>=interval)

The alarm interval to set for each bit collection round, in seconds.  
This is approximately how long each raw bit candidate will take to 
compute; actual returned bits may take 2-3 times longer due to lost bits 
due to debiasing.  A higher or lower value will affect raw 
(pre-debiasing) entropy distribution, and setting this too low could 
cause all data to become zero.

When not set, twuewand uses an adaptive mode which figures out how 
quickly a bit can safely be generated.

=item B<-b> bytes (B<--bytes>=bytes)

The number of bytes to generate.  If both --bytes and --seconds are set, 
twuewand will exit when either condition is satisfied first.

=item B<-s> seconds (B<--seconds>=seconds)

The number of seconds to generate bytes.  This can be a fraction of a 
second.  If both --bytes and --seconds are set, twuewand will exit when 
either condition is satisfied first.

=item B<-q> (B<--quiet>)

Do not print status information to STDERR.

=item B<-v> (B<--verbose>)

Print additional information to STDERR.

=item B<--no-debias>

Do not perform any sort of debiasing on the output returned from the 
TrueRand procedure.

=item B<--no-md5>

=item B<--no-sha>

=item B<--no-aes>

Do not use MD5, SHA(256) or AES (Rijndael) functionality, even if the 
appropriate modules are available.

=back

=head1 BUGS

None known, many assumed.

=head1 SEE ALSO

=over

=item I<rndaddentropy(8)>

A utility to send entropy directly to Linux's entropy pools

=item Introducing twuewand

http://www.finnie.org/2011/09/25/introducing-twuewand/

=item /dev/random - Wikipedia

http://en.wikipedia.org/wiki//dev/random

=item Hardware random number generator - Wikipedia

http://en.wikipedia.org/wiki/Hardware_random_number_generator

=item Analysis of the Linux Random Number Generator

http://eprint.iacr.org/2006/086.pdf

=item Re: `Random' seed.

http://www.atomicfrog.com/knowledge/security/misc/truerand.c

=back

=head1 AUTHOR

B<twuewand> was written by Ryan Finnie <ryan@finnie.org>.

=cut
