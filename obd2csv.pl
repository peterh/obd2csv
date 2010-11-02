#!/usr/bin/perl

use 5.10.0;
use warnings;
use strict;

my $port = '/dev/ttyACM0';
my $baud = 9600;

use Time::HiRes qw( usleep );
use Device::SerialPort;
my $obd = new Device::SerialPort($port, 1) or die "Cannot open $port\n";
$obd->baudrate($baud);
$obd->parity("none");
$obd->databits(8);
$obd->stopbits(1);
$obd->handshake('rts');
$obd->write_settings or die "Cannot configure $port\n";

sub cmd {
    my $command = shift;
    $obd->write($command."\r\n");

    my $rv = '';
    while (1) {
        my ($count, $bytes);
        ($count, $bytes) = $obd->read(100);
        if ($count) {
            $bytes =~ tr/\000//d;
            $rv .= $bytes;
        }
        if (substr($rv, -1) eq '>') {
            chop $rv;
            return $rv;
        }
        usleep(10);
    }
}

sub bytes {
    my $in = shift;
    my $trim = shift // 0;
    my $rv = '';

    my @lines = split("[\r\n]+", $in);
    for my $line (@lines) {
        my @bytes = split(" +", $line);
        my $bline = '';
        for my $byte (@bytes) {
            if ($byte =~ /^[0-9a-fA-F]{2}$/) {
                $bline .= chr(hex($byte));
            }
        }
        $rv .= substr($bline, $trim) if (length($bline) > $trim);
    }
    return $rv;
}

my %mode1;

sub mode1init {
    my $offset = shift // 0;
    my $rv = cmd(sprintf('01%02X', $offset));
    my $bits = bytes($rv, 2);
    if (length($bits) != 4) {
        die("Unexpected error during mode 1 init: $rv\n");
    }
    my @supported = split(//, unpack('B*', $bits));
    for my $i (1..0x20) {
        $mode1{$i + $offset} = 1 if ($supported[$i-1]);
    }
    mode1init($offset + 0x20) if ($mode1{0x20 + $offset});
}

cmd('ATZ');   # Reset
cmd('AT E0');  # Echo off

my $ver = cmd('ATI');
chomp($ver);
say "Interface version: $ver";

say "VIN\n", cmd('0902');
say "09 supported\n", cmd('0900');
say "09 01\n", cmd('0901');

mode1init();
say "01 supported: ";
say join(', ', map { sprintf('%02X', $_); } sort keys %mode1);

