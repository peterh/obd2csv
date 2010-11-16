#!/usr/bin/perl

use 5.10.0;
use warnings;
use strict;

use Getopt::Long;
use Time::HiRes qw( time usleep );
use Device::SerialPort;

my $port = '/dev/ttyACM0';
my $baud = 9600;
my $dtc = '';
my $snap = '';
my @watch = ();
our $error = 0;

GetOptions('baud=i' => \$baud
         , 'dtc'    => \$dtc
         , 'port=s' => \$port
         , 'snap'   => \$snap
         , 'watch=s' => \@watch
          );
@watch = split(/,/,join(',',@watch));

my $obd = new Device::SerialPort($port, 1) or die "Cannot open $port\n";
$obd->baudrate($baud);
$obd->parity("none");
$obd->databits(8);
$obd->stopbits(1);
$obd->handshake('rts');
$obd->write_settings or die "Cannot configure $port\n";

# Drain input buffer
$obd->read(1024);

sub dtccount {
    my ($a, $b, $c, $d) = unpack ('C4', shift);
    return $a & 0x7F;
}

sub dtcstatus {
    my ($a, $b, $c, $d) = unpack ('C4', shift);
    my $rv;
    $rv .= 'MIL ' if ($a & 0x80);
    $rv .= sprintf('%d DTCs', $a & 0x7F);

    # TODO: test flags

    return $rv;
}
sub fuelstatus {
    my ($a, $b) = unpack ('C2', shift);
    sub decode {
        my $a = shift;
        my $rv;
        if ($a & 1) {
            $rv = 'Open loop: cold';
        } elsif ($a & 2) {
            $rv = 'Closed loop';
        } elsif ($a & 4) {
            $rv = 'Open loop: load or decel';
        } elsif ($a & 8) {
            $rv = 'Open loop: system failure';
        } elsif ($a & 0x10) {
            $rv = 'Closed loop with fault';
        } else {
            $rv = 'Unknown';
        }
        return $rv;
    }
    my $rv = 'OK';
    if ($a) {
        $rv = decode($a);
    }
    if ($b) {
        $rv .= ' B:'.decode($b);
    }
    return $rv;
}
sub percent {
    my $a = unpack ('C', shift);
    return sprintf('%.1f',$a * 100/255.0);
}
sub degrees {
    my $a = unpack ('C', shift);
    return sprintf('%d',$a - 40);
}
sub signedpercent {
    my $a = unpack ('C', shift);
    return sprintf('%.1f',($a - 128) * 100/128.0);
}
sub timesone {
    my $a = unpack ('C', shift);
    return sprintf('%d',$a);
}
sub rpm {
    my $a = unpack ('n', shift);
    return sprintf('%.2f',$a / 4.0);
}
sub advance {
    my $a = unpack ('C', shift);
    return sprintf('%.2f',($a / 2.0) - 64);
}
sub maf {
    my $a = unpack ('n', shift);
    return sprintf('%.3f',$a / 100.0);
}
sub o2present {
    my $a = unpack ('C', shift);
    my @list;
    for my $i (0..3) {
        push @list, 'B1S'.($i+1) if ($a & (1 << $i));
    }
    for my $i (4..7) {
        push @list, 'B2S'.($i-3) if ($a & (1 << $i));
    }
    return join ',', @list;
}
sub o2 {
    my ($a, $b) = unpack ('C2', shift);
    my $rv;
    $rv = sprintf('%.3f / ', $a * 0.005);
    if ($b == 0xFF) {
        $rv .= 'Unused';
    } else {
        $rv .= sprintf('%.2f', ($b - 128) * 100 / 128.0);
    }
    return $rv;
}
sub obdstandard {
    my $a = unpack ('C', shift);
    given ($a) {
        when (1) { return 'OBD-II (CARB)'; }
        when (2) { return 'OBD (EPA)'; }
        when (3) { return 'OBD and OBD-II'; }
        when (4) { return 'OBD-I'; }
        when (5) { return 'None'; }
        when (6) { return 'EOBD'; }
        when (7) { return 'EOBD and OBD-II'; }
        when (8) { return 'EOBD and OBD'; }
        when (9) { return 'EOBD, OBD and OBD-II'; }
        when (0xA) { return 'JOBD'; }
        when (0xB) { return 'JOBD and OBD-II'; }
        when (0xC) { return 'JOBD and EOBD'; }
        when (0xD) { return 'JOBD, EOBD and OBD-II'; }
        default { return sprintf('Unknown (0x%02X)', $a); }
    }
}
sub msbtimesone {
    my $a = unpack ('n', shift);
    return sprintf('%d',$a);
}

my @pid = (
    undef,    #00
    { name => 'DTC Status', length => 4, units => undef, format => \&dtcstatus },
    undef,
    { name => 'Fuel System', length => 2, units => undef, format => \&fuelstatus },
    { name => 'Engine Load', length => 1, units => '%', format => \&percent },
    { name => 'Coolant Temp', length => 1, units => 'deg C', format => \&degrees },
    { name => 'Short Trim 1', length => 1, units => '%', format => \&signedpercent },
    { name => 'Long Trim 1', length => 1, units => '%', format => \&signedpercent },
    { name => 'Short Trim 2', length => 1, units => '%', format => \&signedpercent },
    { name => 'Long Trim 2', length => 1, units => '%', format => \&signedpercent },
    undef, # 0x0A 'Fuel Pressure'
    { name => 'Intake Pressure', length => 1, units => 'kPa', format => \&timesone },
    { name => 'RPM', length => 2, units => undef, format => \&rpm },
    { name => 'Speed', length => 1, units => 'km/h', format => \&timesone },
    { name => 'Timing Advance', length => 1, units => 'degrees', format => \&advance },
    { name => 'Intake Air Temp', length => 1, units => 'deg C', format => \&degrees },
    { name => 'MAF air rate', length => 2, units => 'g/s', format => \&maf }, # 0x10
    { name => 'Throttle', length => 1, units => '%', format => \&percent },
    undef, # 0x12 'Secondary Air Status'
    { name => 'O2 Sensors', length => 1, units => undef, format => \&o2present },
    { name => 'O2 1/1', length => 2, units => 'V / %', format => \&o2 },
    { name => 'O2 1/2', length => 2, units => 'V / %', format => \&o2 },
    { name => 'O2 1/3', length => 2, units => 'V / %', format => \&o2 },
    { name => 'O2 1/4', length => 2, units => 'V / %', format => \&o2 },
    { name => 'O2 2/1', length => 2, units => 'V / %', format => \&o2 },
    { name => 'O2 2/2', length => 2, units => 'V / %', format => \&o2 },
    { name => 'O2 2/3', length => 2, units => 'V / %', format => \&o2 },
    { name => 'O2 2/4', length => 2, units => 'V / %', format => \&o2 },
    { name => 'OBD Standard', length => 1, units => undef, format => \&obdstandard },
    undef, # 0x1D - O2 present (2)
    undef, # 0x1E - Aux Input Status
    { name => 'Run Time', length => 2, units => 'seconds', format => \&msbtimesone },
    undef, # 0x20
    { name => 'MIL Distance', length => 2, units => 'km', format => \&msbtimesone },
);

sub dtcformat {
    my @letter = ('P', 'C', 'B', 'U');
    my $dtc = shift;
    return sprintf('%s%04X',$letter[$dtc >> 14], $dtc & 0x3FFF);
}

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

sub quote {
    my $item = shift;
    chomp $item;
    $item =~ s/"/""/g;
    $item = '"'.$item.'"';
    return $item;
}

# CAN-bus has a different long format
sub canbytes {
    my $bline = '';
    for my $line (@_) {
        my @bytes = split(" +", $line);
        for my $byte (@bytes) {
            if ($byte =~ /^[0-9a-fA-F]{2}$/) {
                $bline .= chr(hex($byte));
            }
        }
    }
    return $bline;
}

sub bytes {
    my $in = shift;
    my $trim = shift // 0;
    my $rv = '';

    my @lines = split("[\r\n]+", $in);
    for my $line (@lines) {
        if ($line =~ /^[\da-fA-F]{3}$/) {
            my $bline = canbytes(@lines);
            $rv .= substr($bline, $trim) if (length($bline) > $trim);
            return $rv;
        }
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

sub modeinit {
    my @list;
    my $mode = shift;
    my $tail = shift // '';
    my $trim = 2;
    if (length($tail)) {
        $trim = 3;
    }
    my $offset = shift // 0;
    my $rv = cmd(sprintf("%02X%02X$tail", $mode, $offset));
    my $bits = bytes($rv, $trim);
    if (length($bits) != 4) {
        die("Unexpected error during mode $mode init: $rv\n");
    }
    my @supported = split(//, unpack('B*', $bits));
    for my $i (1..0x1F) {
        push @list, ($i + $offset) if ($supported[$i-1]);
    }

    push @list, modeinit($mode, $tail, $offset + 0x20) if ($supported[0x20 - 1]);

    return @list;
}

sub getval {
    my $i = shift;
    my $format = shift;

    my $send = sprintf($format,$i);
    my $value;
    my $cmd = cmd($send);
    my $bytes = bytes($cmd, length($send)/2);
    if (length($bytes) != $pid[$i]->{length}) {
        $value = "Error: $cmd";
        $error++;
    } else {
        $value = $pid[$i]->{format}($bytes);
    }
    return $value;
}

sub lineitem {
    my $i = shift;
    my $format = shift;
    if (!defined $pid[$i]) {
        say quote('Unknown PID '.$i);
        return;
    }
    my $type = $pid[$i]->{name};
    $type .= ' ('.$pid[$i]->{units}.')' if (defined $pid[$i]->{units});

    say quote($type).','.quote(getval($i, $format));
}

cmd('ATZ');   # Reset
cmd('AT E0');  # Echo off

my $ver = cmd('ATI');
chomp($ver);
say '"Interface version",'. quote($ver);

my $vin = bytes(cmd('0902'),3);
$vin =~ s/\x00//g;    # Trim leading NUL bytes
$vin = 'Unknown' if ($vin =~ /\xFF/);
say '"VIN",'. quote($vin);

if ($dtc) {
    my %mode2 = map { $_ => 1 } modeinit(2, '00');
    
    my $dtcs = dtccount(bytes(cmd('0101'), 2));
    say '"Number of DTCs",'.quote($dtcs);
    if ($dtcs) {
        my $list = bytes(cmd('03'), 1);
        my @dtcs = unpack('n*', $list);
        my @fmt;
        for my $i (1..$dtcs) {
            push @fmt, dtcformat($dtcs[$i-1]);
        }
        say '"DTCs",'. quote(join(',',@fmt));

        $list = bytes(cmd('07'), 1);
        @dtcs = unpack('n*', $list);
        @fmt = ();
        for my $dtc (@dtcs) {
            push @fmt, dtcformat($dtc) if $dtc;
        }
        say '"Next DTCs",'. quote(join(',',@fmt));
    
        say '';
        my $ff = cmd('020200');
        my $dtc = bytes($ff, 3);
        die "Invalid Freeze Frame Number $ff\n" if (length($dtc) != 2);
    
        say '"Freeze Frame",'. quote(dtcformat(unpack('n', $dtc)));
        for my $i (sort keys %mode2) {
            next if ($i == 1);   # PID 1 not valid in mode 2
            lineitem($i, '02%02X00');
        }
    }
} elsif ($snap) {
    my %mode1 = map { $_ => 1 } modeinit(1);
    
    say '"Supported codes","'.
         join(', ',
             map { sprintf('%02X', $_); } sort { $a <=> $b } keys %mode1).
         '"';

    for my $i (sort keys %mode1) {
        lineitem($i, '01%02X');
    }
} elsif (scalar @watch) {
    my %mode1 = map { $_ => 1 } modeinit(1);

    my @warn = grep { !$mode1{hex($_)} } @watch;
    if (scalar @warn) {
        say '"Unsupported codes",'. join(',',@warn);
    }

    @watch = map(hex,@watch);
    @watch = grep { $mode1{$_} } @watch;
    my @names = map { 
       my $type = $pid[$_]->{name};
       $type .= ' ('.$pid[$_]->{units}.')' if (defined $pid[$_]->{units});
       $type;
    } @watch;
    say '"Time",'.join(',', map { quote($_) } @names);

    while (!$error) {
        my @val;

        my $time = time();
        my ($sec, $min, $hour) = localtime($time);
        $sec += ($time - int($time));

        push @val, sprintf('%02d:%02d:%02.4f',$hour,$min,$sec);
        for my $i (@watch) {
            push @val, getval($i, '01%02X');
        }

        say join(',', map { quote($_) } @val);
    }

} else {
    say "Nothing to do.";
}
