package FusionInventory::Agent::Task::Inventory::Linux::Storages;

use strict;
use warnings;

use parent 'FusionInventory::Agent::Task::Inventory::Module';

use English qw(-no_match_vars);
use File::Basename qw(basename);

use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Generic;
use FusionInventory::Agent::Tools::Linux;
use FusionInventory::Agent::Tools::Unix;

sub isEnabled {
    my (%params) = @_;
    return 0 if $params{no_category}->{storage};
    return 1;
}

sub doInventory {
    my (%params) = @_;

    my $inventory = delete $params{inventory};

    $params{root} = $params{test_path} || "";

    foreach my $device (_getDevices(%params)) {
        $inventory->addEntry(section => 'STORAGES', entry => $device);
    }
}

sub _getDevices {
    my (%params) = @_;

    my $root   = $params{root};

    my @devices = _getDevicesBase(%params);

    # complete with udev for missing bits, if available
    if (-d "$root/dev/.udev/db/") {

        my %udev_devices = map { $_->{NAME} => $_ }
            getDevicesFromUdev(%params);

        foreach my $device (@devices) {
            # find corresponding udev entry
            my $udev_device = $udev_devices{$device->{NAME}};
            next unless $udev_device;

            foreach my $key (keys %$udev_device) {
                next if $device->{$key};
                $device->{$key} = $udev_device->{$key};
            }
        }
    }

    # get serial & firmware numbers from hdparm, if available
    if (_correctHdparmAvailable(%params)) {
        foreach my $device (@devices) {
            next if $device->{SERIALNUMBER} && $device->{FIRMWARE};
            my $info = getHdparmInfo(
                device => "/dev/" . $device->{NAME},
                %params
            );

            $device->{SERIALNUMBER} = $info->{serial}
                if $info->{serial} && !$device->{SERIALNUMBER};

            $device->{FIRMWARE} = $info->{firmware}
                if $info->{firmware} && !$device->{FIRMWARE};

            $device->{DESCRIPTION} = $info->{transport} if $info->{transport};
            $device->{MODEL}       = $info->{model} if $info->{model};
            $device->{WWN}         = $info->{wwn} if $info->{wwn};
        }
    }

    foreach my $device (@devices) {
        $device->{DESCRIPTION} = _fixDescription(
            $device->{NAME},
            $device->{MANUFACTURER},
            $device->{DESCRIPTION},
            $device->{SERIALNUMBER}
        );

        if (!$device->{MANUFACTURER} || $device->{MANUFACTURER} eq 'ATA') {
            $device->{MANUFACTURER} = getCanonicalManufacturer(
                $device->{MODEL}
            );
        } elsif ($device->{MANUFACTURER} && $device->{MANUFACTURER} =~ /^0x(\w+)$/) {
            my $vendor = getPCIDeviceVendor(id => lc($1));
            $device->{MANUFACTURER} = $vendor->{name}
                if $vendor && $vendor->{name};
        }

        if (!$device->{DISKSIZE} && $device->{TYPE} !~ /^cd/) {
            $device->{DISKSIZE} = getDeviceCapacity(
                device => '/dev/' . $device->{NAME},
                %params
            );
        }

        # In some case, serial can't be defined using hdparm (command missing or virtual disk)
        # Then we can define a serial searching for few specific identifiers
        # But avoid to search S/N for empty removable meaning no disk has been inserted
        if (!$device->{SERIALNUMBER} && !($device->{TYPE} eq 'removable' && !$device->{DISKSIZE})) {
            $params{device} = '/dev/' . $device->{NAME};
            my $sn = _getDiskIdentifier(%params) || _getPVUUID(%params);
            $device->{SERIALNUMBER} = $sn if $sn;
        }
    }

    return @devices;
}

sub _getDevicesBase {
    my (%params) = @_;

    # We need to support dump params to permit full testing when root params is set
    my $root   = $params{root};
    my $logger = $params{logger};
    $logger->debug("retrieving devices list:");

    if (-d "$root/sys/block") {
        my @devices = getDevicesFromProc(%params);
        $logger->debug_result(
            action => 'reading /sys/block content',
            data   => scalar @devices
        );
        return @devices if @devices;
    } else {
        $logger->debug_result(
            action => 'reading /sys/block content',
            status => 'directory not available'
        );
    }

    if ((!$root && canRun("/usr/bin/lshal")) || ($root && -e "$root/lshal")) {
        my @devices = getDevicesFromHal(%params);
        $logger->debug_result(
            action => 'running lshal command',
            data   => scalar @devices
        );
        return @devices if @devices;
    } else {
        $logger->debug_result(
            action => 'running lshal command',
            status => 'command not available'
        );
    }

    return;
}

sub _fixDescription {
    my ($name, $manufacturer, $description, $serialnumber) = @_;

    # detected as USB by udev
    # TODO maybe we should trust udev detection by default?
    return "USB" if ($description && $description =~ /usb/i);

    if ($name =~ /^sd/) { # /dev/sd* are SCSI _OR_ SATA
        if (
            ($manufacturer && $manufacturer =~ /ATA/) ||
            ($serialnumber && $serialnumber =~ /ATA/) ||
            ($description && $description =~ /ATA/)
        ) {
            return "SATA";
        } else {
            return "SCSI";
        }
    } elsif ($name =~ /^sg/) { # "g" stands for Generic SCSI
        return "SCSI";
    } elsif ($name =~ /^vd/  ||
            ($description && $description =~ /VIRTIO/)
        ) {
            return "Virtual";
    } else {
        return $description || "IDE";
    }
}

# some hdparm release generated kernel error if they are
# run on CDROM device
# http://forums.ocsinventory-ng.org/viewtopic.php?pid=20810
sub _correctHdparmAvailable {
    my (%params) = @_;

    $params{command} = "hdparm -V";

    # We need to support dump params to permit full testing when root params is set
    if ($params{root}) {
        $params{file} = $params{root}."/hdparm";
        return unless -e $params{file};
    }

    return unless canRun('hdparm') || $params{file};

    if ($params{dump}) {
        $params{dump}->{"hdparm"} = getAllLines(%params);
    }

    my ($major, $minor) = getFirstMatch(
        pattern => qr/^hdparm v(\d+)\.(\d+)/,
        %params
    );

    # we need at least version 9.15
    return compareVersion($major, $minor, 9, 15);

}

sub _getDiskIdentifier {
    my (%params) = @_;

    # We need to support dump params to permit full testing when root params is set
    if ($params{root}) {
        $params{file} = $params{root}."/fdisk";
        return unless -e $params{file};
    } else {
        $params{command} = "fdisk -v";
    }

    return unless $params{device} && (canRun("fdisk") || $params{file});

    if ($params{dump}) {
        $params{dump}->{"fdisk"} = getAllLines(%params);
    }

    # GNU version requires -p flag
    $params{command} = getFirstLine(%params) =~ '^GNU' ?
        "fdisk -p -l $params{device}" :
        "fdisk -l $params{device}"    ;

    if ($params{root}) {
        my $devname = basename($params{device});
        $params{file} = $params{root}."/fdisk-$devname";
        return unless -e $params{file};
    } elsif ($params{dump}) {
        my $devname = basename($params{device});
        $params{dump}->{"fdisk-$devname"} = getAllLines(%params);
    }

    my $identifier = getFirstMatch(
        pattern => qr/^Disk identifier:\s*(?:0x)?(\S+)$/i,
        %params
    );

    return $identifier;
}

sub _getPVUUID {
    my (%params) = @_;

    # We need to support dump params to permit full testing when root params is set
    if ($params{root}) {
        my $devname = basename($params{device});
        $params{file} = $params{root}."/lvm-$devname";
        return unless -e $params{file};
    }

    return unless $params{device} && (canRun("lvm") || $params{file});

    $params{command} = "lvm pvdisplay -C -o pv_uuid --noheadings $params{device}" ;

    if ($params{dump}) {
        my $devname = basename($params{device});
        $params{dump}->{"lvm-$devname"} = getAllLines(%params);
    }

    my $uuid = getFirstMatch(
        pattern => qr/^\s*(\S+)/,
        %params
    );

    return $uuid;
}

1;
