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
use IO::Handle;
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
  'bytes|b=i' => \$opt_bytes,
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
  # 20ms becomes the default starting point in adaptive mode.
  $opt_interval = 0.02;
}

# Do not use a smaller interval than CLOCK_REALTIME.
my($min_interval) = Time::HiRes::clock_getres(Time::HiRes::CLOCK_REALTIME());
if($opt_interval < $min_interval) {
  $opt_interval = $min_interval;
}

# Data stored (up to $outbufflimit bytes) before debiasing/outputting
my($outbuff) = "";

# Signal handlers
$SIG{ALRM} = "tick";
$SIG{INT} = "sig_int";

# These variables must be global since the alarm handler relies on them
my($increment) = 0;
my($discardedbitcnt) = 0;
my($tickbuff) = 0;
my($tickbuffcnt) = 0;
my($outbitscnt) = 0;
my($outbitsint) = 0;

my($rawbitsint, $rawbitscnt, $sha, $shastreamcnt, $shabuff);
if($has_hash && $has_sha && $has_aes) {
  # Raw (non-Von Neumann) bits are used to seed a global SHA256 hash.
  $rawbitscnt = 0;
  $rawbitsint = 0;
  $shastreamcnt = 0;
  $shabuff = '';
  $sha = Digest::SHA->new(256);
}

# Target number of flips per byte, FIPS 140-2
# (99.993% confidence (Z=4.0), 0.01 max error)
my $adaptive_target = (4.0 ** 2) / (4 * (0.01 ** 2));
# Average calculated interval.
my $ewma = 0;
# Round length will increase from 2 to 32 bits.
my $round_length = 2;

if(!$opt_quiet) {
  print STDERR "Generated: 0 bytes";
}
my $started = time();
my $reqbytesi = 0;
while(1) {
  # Set the alarm
  $increment = 0; alarm($opt_interval);

  # Increment a number until the round is over.
  # Note: the alarm handler will reset $increment to 0 after a
  # bit is generated.
  while($tickbuffcnt < $round_length) {
    $increment++;
  }

  if($opt_debias) {
    while($tickbuffcnt > 1) {
      # Take two bits from the tick buffer
      my $statebitint = $tickbuff % 4;
      $tickbuff = $tickbuff >> 2;
      $tickbuffcnt -= 2;

      if($has_hash && $has_sha && $has_aes) {
        # The raw bits (all bits, not just bits which pass Von Neumann) are 
        # only used to seed a SHA256 key.  Every time we have 8 full bits, 
        # put a byte into the SHA stream.
        $rawbitsint = ($rawbitsint << 2) | $statebitint;
        $rawbitscnt += 2;
        if($rawbitscnt == 8) {
          $shabuff .= chr($rawbitsint);
          $rawbitscnt = 0;
          $rawbitsint = 0;
        }
      }

      # Von Neumann
      if(($statebitint == 1) || ($statebitint == 2)) {
        $outbitsint = ($outbitsint << 1) | ($statebitint % 2);
        $outbitscnt++;
        $discardedbitcnt++;
      } else {
        $discardedbitcnt += 2;
      }

      # Once we have a full byte, add it to the buffer
      while($outbitscnt >= 8) {
        $outbuff .= chr($outbitsint % 256);
        $outbitsint = $outbitsint >> 8;
        $outbitscnt -= 8;
        $reqbytesi++;
      }
    }
  } else {
    # If no debiasing is to be performed, don't bother with the Von 
    # Neumann dance.  Instead, add the tick buffer directly to the 
    # output buffer.
    while($tickbuffcnt >= 8) {
      $outbuff .= chr($tickbuff % 256);
      $tickbuff = $tickbuff >> 8;
      $tickbuffcnt -= 8;
      $reqbytesi++;
    }
  }

  if($opt_adaptive) {
    # Update the target interval
    if($ewma == 0) {
      $ewma = ($adaptive_target / ($increment / $opt_interval)) * 8;
    } else {
      $ewma = $ewma + (($adaptive_target / ($increment / $opt_interval)) - ($ewma / 8));
    }
    $opt_interval = $ewma / 8;

    # If the calculated interval is lower than Time::HiRes's
    # CLOCK_REALTIME, use CLOCK_REALTIME instead.
    if($opt_interval < $min_interval) {
      $opt_interval = $min_interval;
    }
  }

  # Increase the round length as we get better at calculating times.
  if($round_length < 32) {
    $round_length += 2;
  }

  # If we generated too many bytes, strip some off.
  if($opt_bytes && ($reqbytesi > $opt_bytes)) {
    $outbuff = substr($outbuff, 0, ($reqbytesi - $opt_bytes));
    $discardedbitcnt += (($opt_bytes - $reqbytesi) * 8);
    $reqbytesi = $opt_bytes;
  }

  if(!$opt_quiet) {
    if($opt_bytes) {
      printf STDERR "%sGenerated: %d/%d bytes (%3d%%)", chr(13), $reqbytesi, $opt_bytes, ($reqbytesi / $opt_bytes * 100);
    } else {
      printf STDERR "%sGenerated: %d bytes", chr(13), $reqbytesi;
    }
    if($opt_seconds) {
      printf STDERR " (%d/%ds)", (time() - $started), $opt_seconds;
    }
  }

  # If we start to have a lot of data in the output buffer, output the 
  # fully debiased buffer and start again.  We don't want to do this 
  # too often, since each output takes a significant time penalty (SHA 
  # + AES at worst).
  if(length($outbuff) >= $outbufflimit) {
    process_buffer();
  }

  last if($opt_seconds && (time() >= ($started + $opt_seconds)));
  last if($opt_bytes && ($reqbytesi >= $opt_bytes));
}

finalize_run();
exit;

sub finalize_run {
  # If there are any bytes left in the buffer, output the fully debiased 
  # buffer.
  if(length($outbuff) > 0) {
    process_buffer();
  }

  if(!$opt_quiet) { print STDERR "\n"; }
  if($opt_verbose) {
    my $total_bits = $reqbytesi * 8 + $discardedbitcnt;
    printf STDERR "Raw speed was %0.02f bps at the end.\n", 1 / $opt_interval;
    if($discardedbitcnt > 0) {
      printf STDERR "Used %d extra bits (%d%%) of overhead.\n", $discardedbitcnt, $discardedbitcnt / $total_bits * 100;
    }
    if($has_sha && $shastreamcnt) {
      printf STDERR "Seeded %d bytes into the SHA key.\n", $shastreamcnt;
    }
  }
}

sub process_buffer {
  my $out;

  my $outbufflen = length($outbuff);
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

  STDOUT->printflush($outbuff);

  $outbuff = "";
  $outbufflen = 0;
}

sub tick {
  # We have a random bit!
  $tickbuff = ($tickbuff << 1) | ($increment % 2);
  $tickbuffcnt++;

  # If we still need more bits, schedule a new alarm
  if($tickbuffcnt < $round_length) {
    $increment = 0; alarm($opt_interval);
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
