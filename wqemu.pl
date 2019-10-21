#!/usr/bin/env perl

# KNOWN ISSUES
#
# https://bugs.launchpad.net/qemu/+bug/1798451
# SMP works not
#

#
# monitor -> system_powerdown
# monitor -> quit
#
# actions:
#
# console
# monitor
# poweroff
# 
#
#
use strict;
use warnings;

use YAML;
use Data::Dumper;
use Getopt::Long qw(:config require_order);
use IPC::Open3;
use Symbol 'gensym';

# only configurable
my $scriptpath="/Users/de/Documents/Devel/Qemu";
my $default_bios="$scriptpath/OVMF-pure-efi.fd";
my $machines="/Users/de/Qemu";

sub usage {
    my ($s)=@_;

    print $s,"\n\n" if($s);
    print <<EOF;
Usage: wqemu [-h|--help] [-n|--no-action] <action> [<VM>]

Home-made script to manage qemu virtual machines due to lack of
other viable frontend on macOS.

Actions:

    create <name>
        --iso|-i <string>     ISO file to use (mandatory, no default)
        --bios|-b <string>    BIOS file to use (default: $default_bios)
        --disk|-d <int>       Disk size in GB (default: 20)
        --mem|-m <int>        Memory in MB (default: 1024)

    start <name>
        --no-action|-n        Just print the command line, no-execute
        --console|-c          Foreground with graphical console window

        Note: will create a socket "console" in the machine dir
        (e.g. $machines/my-vm/console) for the serial console.
        Connect to that machine with e.g.
        socat -,raw,echo=0,escape=0xf UNIX-CONNECT:$machines/my-vm/console
        To quit: use CTRL-V CTRL-O

    powerdown <name>
        Use the monitor to system_powerdown the VM.
        Caution: if the monitor is already connected,
        the powerdown seems to be queded and executed on console disconnect,
        which can be surprising

    quit <name>
        Use the monitor to "quit the emulator", i.e. hard/immediate stop.
        Caution: see powerdown

    console <name>
        Connect to the console

    monitor <name>
        Connect to the qemu monitor

    list
        --long|-l             Long output

    kill <name>
        --signal|-s           Signal to send. Default: pgrep's default

    snapshot <name>
        --action|-a <string>  Actions: create, list, delete, apply
       [action-args]          All actions but list take a -s <snapname> argument

       Examples:
           snapshot -a create -s pre-upgrade centos7-template
           snapshot -a list centos7-template
           snapshot -a apply -s pre-upgrade centos7-template
           snapshot -a delete -s pre-upgrade centos7-template

       Caveat:
           Deleting a snapshot is like deleting a git tag
           Applying a snapshot is like "revert to snapshot"

    clone <name>
        --no-action|-n        Just print the command line, no-execute
        -t <string>           Clone target name

    print-defaults
                              Print something suitable to paste
                              into "$scriptpath/globals.yml"

Description / how it works

Assume the script lives in $scriptpath and the virtual machines live in
$machines.

In the $machines directory, there is a subdirectory for each VM, which holds
the machine.yml file describing the VM, and the discs in qcow2 format. Use the
create action to create a machine and inspect the directoty tree and the
machines.yml file.

Deleting a VM just goes by removing the VM directory recursively. No other
magic happens.

EOF
}

sub do_start {
    my $noaction;
    my $console;
    #my $long_output;
    GetOptions (
        "no-action|n"  => \$noaction,
        "console|c" => \$console)
    or die("Error in start arguments\n");

    if(scalar @ARGV<1) {
        usage("Usage: start: no argument (= VM to start) given!");
        exit(1);
    }

    if(scalar @ARGV>1) {
        usage("Usage: start: takes exactly one argument (=VM to start)!");
        exit(1);
    }

    my $machine_dir;
    $machine_dir="$machines/$ARGV[0]";

    unless($machine_dir && $machine_dir ne "") {
        usage("Error: no machine directory given");
        exit(1);
    }

    unless(-d $machine_dir) {
        usage("Error: $machine_dir: $!");
        exit(1);
    }

    unless(-f "$machine_dir/machine.yml") {
        usage("Error: $machine_dir/machine.yml: $!");
        exit(1);
    }

    unless(-r "$machine_dir/machine.yml") {
        usage("Error: $machine_dir/machine.yml: $!");
        exit(1);
    }

    my ($hashref, $arrayref, $string) = YAML::LoadFile("$machine_dir/machine.yml");

    my $machine_href=$hashref;

    my $qemu=$machine_href->{'qemu'} || $::globals->{'qemu'};
    my $accel=$machine_href->{'accel'} || $::globals->{'accel'};
    my $cpu=$machine_href->{'cpu'} || $::globals->{'cpu'};
    my $machine=$machine_href->{'machine'} || $::globals->{'machine'};
    my $keyboard=$machine_href->{'keyboard'} || $::globals->{'keyboard'};

    my $name=$machine_href->{'name'} || $::globals->{'name'};
    my $mem=$machine_href->{'mem'} || $::globals->{'mem'};
    my $discs=$machine_href->{'discs'} || $::globals->{'discs'};
    my $nics=$machine_href->{'nics'} || $::globals->{'nics'};

    my $iso=$machine_href->{'iso'};
    my $bios=$machine_href->{'bios'};

    #
    # validate
    #
    unless($qemu eq "qemu-system-x86_64") { usage("qemu $qemu not supported."); exit(1); }
    unless($accel eq "hvf") { usage("accel $accel not supported."); exit(1); }
    unless($cpu eq "host") { usage("cpu $cpu not supported."); exit(1); }
    unless($name =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/) { usage("name $name invalid."); exit(1); }
    unless($machine eq "q35") { usage("machine $machine not supported."); exit(1); }
    unless($mem =~ /^[0-9]+$/) { usage("memory $mem should be numeric, unit is M."); exit(1); }
    unless($keyboard =~ /^[a-z][a-z]$/) { usage("keyboard $keyboard should be a plain 2 letter string I guess."); exit(1); }

    my @args=();

    push @args, ("sudo", $qemu);
    push @args, ("-accel", $accel);
    push @args, ("-cpu", $cpu);
    push @args, ("-name", $name);
    push @args, ("-machine", $machine);
    push @args, ("-m", $mem);
    push @args, ("-k", $keyboard);
    for my $d (@{$discs}) {
        my $hw=$d->[0];
        my $file=$d->[1];

        unless(-f "$machine_dir/$file") { usage("$machine_dir/$file: $!"); exit(1); }
        unless(-r "$machine_dir/$file") { usage("$machine_dir/$file: $!"); exit(1); }
        if($hw) {
            push @args, ("-drive", "file=$machine_dir/$file,if=$hw");
        }
        else {
            push @args, ("-drive", "file=$machine_dir/$file");
        }
    }
    my $nici=0;
    for my $n (@{$nics}) {
        my $hw=$n->[0] || "e1000";
        my $mac=$n->[1];
        my $bridge=$n->[2];

        unless($mac =~ /^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$/){ usage("mac $mac not a valid mac address."); exit(1); }
        unless($bridge =~ /^bridge[0-9]+$/) { usage("bridge $bridge seems invalid."); exit(1); }

        my $upscript=sprintf "$scriptpath/netdev-up-%s.sh", $bridge;
        my $downscript=sprintf "$scriptpath/netdev-down-%s.sh", $bridge;
        my $netdev = sprintf "tap,id=mynet%d,br=%s,script=%s,downscript=%s", $nici, $bridge, $upscript, $downscript;
        my $device = sprintf "$hw,netdev=mynet%d,mac=%s", $nici, $mac;

        push @args, ("-netdev", $netdev);
        push @args, ("-device", $device);
        $nici++;
    }

    #push @args, ("-display", "none") unless ($console);
    push @args, ("-display", "none", "-daemonize") unless ($console);
    # -daemonize not tested with the serial console, but why should it not work?

    # NEW: give all the machines a serial device
    # pty seems to work, can use screen /dev/ttysxyz, but cant easily tell which tty belongs to which VM
    #push @args, ("-chardev", "pty,id=charserial0", "-device", "isa-serial,chardev=charserial0,id=serial0");

    # use with sudo socat -,raw,echo=0,escape=0xf UNIX-CONNECT:console
    # to quit: use CTRL-V CTRL-O
    push @args, ("-chardev", "socket,path=$machine_dir/console,server,nowait,id=charserial0", "-device", "isa-serial,chardev=charserial0,id=serial0");

    push @args, ("-monitor", "unix:$machine_dir/monitor,server,nowait");

    push @args, ("-cdrom", $iso, "-boot", "d") if($iso);

    push @args, ("-bios", $bios) if($bios);

    printf "Command line: %s\n", join(" ", @args);

    my $pid=`pgrep -f '^qemu-system-x86_64.*-name +$name +'`;

    if($pid) {
        print "Error: some 'qemu-system-x86_64 -name $name' seems already running, refusing to start another one.\n";
    }
    else {
        if($noaction) {
            print "Not executing due to no-action mode.\n";
        }
        else {
            print "Executing.\n";
            system(@args)
        }
    }
}

sub do_list {
    my $long_output;
    GetOptions (
        "long|l" => \$long_output)
    or die("Error in start arguments\n");

    if(scalar @ARGV>0) {
        usage("Usage: list (and no further arguments)!");
        exit(1);
    }

    my @lines=`pgrep -l -f '^qemu-system-x86_64'`;

    for my $l (@lines) {
        chomp $l;
        $l =~ s/.* -name ([^ ]*).*/$1/ unless($long_output);
        print $l,"\n";
    }
}

sub do_create {
    my $iso;
    my $mem=1024;
    my $bios=$default_bios;
    my $disksize=20;
    GetOptions (
        "iso|i=s" => \$iso,
        "bios|b=s" => \$bios,
        "disk|d=i" => \$disksize,
        "mem|m=i" => \$mem
    )
    or die("Error in create arguments\n");

    if(scalar @ARGV<1) {
        usage("Usage: create got no argument (= VM to create) given!");
        exit(1);
    }

    if(scalar @ARGV>1) {
        usage("Usage: create takes exactly one argument (=VM to start)!");
        exit(1);
    }

    if(! $iso) {
        print "Error: no iso given.\n";
        exit(1);
    }

    if(! -f $iso) {
        print "Error: iso \"$iso\": no such file.\n";
        exit(1);
    }
    
    my $name=$ARGV[0];
    unless($name =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/) { usage("name $name invalid."); exit(1); }

    my $bridges=$::globals->{'bridges'};
    printf "Bridges: ";
    print Dump($bridges);

    # create dir
    # create empty qcow2 file therein
    # create standard machine template with random macs

    my $machine_dir;
    $machine_dir="$machines/$ARGV[0]";

    if(-d "$machine_dir") {
        print "Error: directory \"$machine_dir\" already exists.\n";
        exit(1);
    }

    mkdir($machine_dir);

    system("qemu-img", "create", "-f", "qcow2", "$machine_dir/disc0.qcow2", "${disksize}G");


    # TODO more flexibe, less hardcoded
    # and maybe even check for duplicates -.-
    #my $mac1=sprintf "52:54:00:%02x:%02x:%02x", int(rand(256)), int(rand(256)), int(rand(256));
    #my $mac2=sprintf "52:54:00:%02x:%02x:%02x", int(rand(256)), int(rand(256)), int(rand(256));
    
    my @nics = ();
    for my $bridge (@$bridges) {
        my $mac=sprintf "52:54:00:%02x:%02x:%02x", int(rand(256)), int(rand(256)), int(rand(256));
        push @nics, ['virtio-net-pci', $mac, $bridge];
    }

    my %machine;
    $machine{'name'}=$name;
    $machine{'discs'}=[ ['virtio', 'disc0.qcow2'] ];
    $machine{'mem'}=$mem; # int($mem);
    $machine{'iso'}=$iso;
    $machine{'bios'}=$bios;
    $machine{'nics'}=\@nics;

    print "Resulting machine.yml:\n";
    print Dump(\%machine);

    open my $fh, ">", "$machine_dir/machine.yml";
    print $fh Dump(\%machine);
    close $fh;

#    print $fh <<EOF;
#---
#name: $name
#discs:
#  - [ "virtio", "disc0.qcow2" ]
#mem: $mem
#iso: $iso
#bios: $bios
#nics:
#  - [ "virtio-net-pci", "$mac1", "bridge1" ] 
#  - [ "virtio-net-pci", "$mac2", "bridge2" ] 
#EOF
#
#    close $fh;
}

sub do_console {
    my ($mode)=@_;

    die "should not happen" unless($mode eq "console" or $mode eq "monitor" or $mode eq "powerdown" or $mode eq "quit");

    if(scalar @ARGV<1) {
        usage("Usage: $mode got no argument!");
        exit(1);
    }

    if(scalar @ARGV>1) {
        usage("Usage: $mode takes exactly one argument!");
        exit(1);
    }
    
    my $name=$ARGV[0];
    unless($name =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/) { usage("name $name invalid."); exit(1); }

    my $machine_dir="$machines/$name";

    my $pid=`pgrep -f '^qemu-system-x86_64.*-name +$name +'`;

    my $socket;
    if($mode eq "console") { $socket = "$machine_dir/console"; }
    else { $socket = "$machine_dir/monitor"; }

    my $flags="";
    my $interactive;
    if($mode eq "console" or $mode eq "monitor") { $interactive=1; $flags = ",raw,echo=0,escape=0xf"; }

    if($pid) {
        if(-e "$socket") {
            my @args;
            push @args, ("sudo", "socat", "-$flags", "UNIX-CONNECT:$socket");
            if($interactive) {
                printf "Command line: %s\n", join(" ", @args);
                printf "Spawning socat. Use \"Ctrl-V Ctrl-O\" to disconnect.\n";
                system(@args);

            }
            else {
                my $command="quit";
		$command="system_powerdown" if($mode eq "powerdown");
                my @oargs=("echo", $command, "|");
                push @oargs, @args;
                printf "Command line (somewhat like): %s\n", join(" ",  @oargs);

                my($wtr, $rdr, $err);
                $err = gensym;

                my $child_pid = open3($wtr, $rdr, $err, @args);
                    # 'some cmd and args', 'optarg', ...);

                print "Child pid: $child_pid\n";

                print $wtr "$command\n";
                close $wtr;

                my @stdout=<$rdr>;
                my @stderr=<$err>;
                close $rdr;
                close $err;

                print "Child stdout:\n";
                print join("", @stdout);
                print "Child stderr:\n";
                print join("", @stderr);

                waitpid( $child_pid, 0 );
                my $child_exit_status = $? >> 8;
                printf "Child exit status: %d\n", $child_exit_status;
            }
        }
        else {
            print "Error: no socket $socket, cant connect.\n";
        }
    }
    else {
        print "Error: no 'qemu-system-x86_64 -name $name' seems running, probably cant connect.\n";
    }
}

sub do_kill {
    my $signal;
    GetOptions (
        "signal|s=i" => \$signal)
    or die("Error in start arguments\n");

    if(scalar @ARGV<1) {
        usage("Usage: kill got no argument (= VM to start) given!");
        exit(1);
    }

    if(scalar @ARGV>1) {
        usage("Usage: kill takes exactly one argument (=VM to start)!");
        exit(1);
    }
    
    my $name=$ARGV[0];
    unless($name =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/) { usage("name $name invalid."); exit(1); }

    my $pid=`pgrep -f '^qemu-system-x86_64.*-name +$name +'`;

    if($pid) {
        #print "Error: some 'qemu-system-x86_64 -name $name' seems already running, refusing to start another one.\n";
        my $sigargs="";
        if(defined $signal) { $sigargs="-$signal"; }
        my $output=`sudo pkill $sigargs -f '^qemu-system-x86_64.*-name +$name +'`;

        print "Killed; Output was \"$output\"\n";
    }
    else {
        print "Error: no 'qemu-system-x86_64 -name $name' seems running, nothing to kill.\n";
    }

}

sub do_snapshot {
    my $noaction;
    my $action;
    my $snap;
    GetOptions (
        "no-action|n" => \$noaction,
        "action|a=s" => \$action,
        "snap|s=s" => \$snap
    )
    or die("Error in snapshot arguments\n");

    if(scalar @ARGV != 1) {
        print "Usage: snapshot needs exactly one argument (VM to snapshot)!\n";
        exit(1);
    }

    unless($action) {
        print "Usage: snapshot: no action given!\n";
        exit(1);
    }

    unless($action eq "create" or $action eq "apply" or $action eq "delete" or $action eq "list") {
        print "Usage: snapshot: invalid action, expected one of create apply delete list!\n";
        exit(1);
    }

    if(($action eq "create" or $action eq "apply" or $action eq "delete")) {
        unless($snap) { print "No snapshot name given!\n"; exit(1); }
        unless($snap =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/) { print "Snapshot name \"$snap\" invalid!\n"; exit(1); }
    }

    my $name=$ARGV[0];
    unless($name =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/) { usage("name $name invalid."); exit(1); }

    my $machine_dir;
    $machine_dir="$machines/$ARGV[0]";

    unless(-d $machine_dir) {
        usage("Error: $machine_dir: $!");
        exit(1);
    }

    unless(-f "$machine_dir/machine.yml") {
        usage("Error: $machine_dir/machine.yml: $!");
        exit(1);
    }

    unless(-r "$machine_dir/machine.yml") {
        usage("Error: $machine_dir/machine.yml: $!");
        exit(1);
    }

    my $pid=`pgrep -f '^qemu-system-x86_64.*-name +$name +'`;

    if($pid) {
        print "Error: 'qemu-system-x86_64 -name $name' seems running. We are only doing offline snapshots.\n";
        exit(1);
    }

    my ($hashref, $arrayref, $string) = YAML::LoadFile("$machine_dir/machine.yml");
    my $machine_href=$hashref;

    my $discs=$machine_href->{'discs'} || $::globals->{'discs'};

    for my $d (@{$discs}) {
        my $hw=$d->[0];
        my $file=$d->[1];

        unless(-f "$machine_dir/$file") { print "$machine_dir/$file: $!\n"; exit(1); }
        unless(-r "$machine_dir/$file") { print "$machine_dir/$file: $!\n"; exit(1); }
    }

    my %actions=("create" => "-c", "apply" => "-a", "delete" => "-d", "list" => "-l");

    for my $d (@{$discs}) {
        my $hw=$d->[0];
        my $file=$d->[1];
        my @args;
        if($action eq "list") {
            @args=("qemu-img", "snapshot", $actions{$action}, "$machine_dir/$file");
        }
        else {
            @args=("qemu-img", "snapshot", $actions{$action}, $snap, "$machine_dir/$file");
        }

        if($noaction) {
            printf "[NO-ACTION] Command line: %s\n", join(" ", @args);
        }
        else {
            printf "Command line: %s\n", join(" ", @args);
            system(@args)
        }
    }
}

#
# Cloning is just cp -avr and create new random macs
# The rest of the cloning procedure (change hostname, newaliases, whatever) is
# left to the user
#
sub do_clone {
    my $noaction;
    my $target;

    GetOptions (
        "target|t=s" => \$target,
        "no-action|n" => \$noaction
    )
    or die("Error in clone arguments\n");

    if(scalar @ARGV != 1) {
        print "Error: clone needs exactly one argument (VM to clone)!\n";
        exit(1);
    }

    unless($target) {
        print "Error: clone needs the -t <target> argument for the target clone name!\n";
        exit(1);
    }
    unless($target =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/) { print "Error: clone: target name $target invalid.\n"; exit(1); }

    my $name=$ARGV[0];
    unless($name =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/) { print "Error: clone: name $name invalid.\n"; exit(1); }

    my $machine_dir="$machines/$name";
    my $target_dir="$machines/$target";

    unless(-d $machine_dir) {
        usage("Error: $machine_dir: $!");
        exit(1);
    }

    unless(-f "$machine_dir/machine.yml") {
        usage("Error: $machine_dir/machine.yml: $!");
        exit(1);
    }

    unless(-r "$machine_dir/machine.yml") {
        usage("Error: $machine_dir/machine.yml: $!");
        exit(1);
    }

    if(-e $target_dir) {
        usage("Error: $target_dir already exists!");
        exit(1);
    }

    my $pid=`pgrep -f '^qemu-system-x86_64.*-name +$name +'`;

    if($pid) {
        print "Error: 'qemu-system-x86_64 -name $name' seems running. We are only doing offline cloning.\n";
        exit(1);
    }

    my @args=("cp", "-av", "$machine_dir", "$target_dir");

    if($noaction) {
        printf "[NO-ACTION] Command line: %s\n", join(" ", @args);
    }
    else {
        printf "Command line: %s\n", join(" ", @args);
        system(@args)
    }

    my ($hashref, $arrayref, $string) = YAML::LoadFile("$machine_dir/machine.yml");
    my $machine_href=$hashref;

    my $nics=$machine_href->{'nics'};
    for my $n (@{$nics}) {
        my $new_mac=sprintf "52:54:00:%02x:%02x:%02x", int(rand(256)), int(rand(256)), int(rand(256));
        $n->[1]=$new_mac;
    }
    $machine_href->{'name'}=$target;

    if($noaction) {
        print "[NO-ACTION]: Resulting machine.yml file would be:\n";
        print Dump($hashref);
    }
    else {
        open my $fh, ">", "$target_dir/machine.yml";
        print $fh Dump($machine_href);
        close $fh;
    }
}

sub do_print_defaults {

    if(scalar @ARGV>0) {
        usage("Usage: print-defaults takes no arguments!");
        exit(1);
    }
    
    print <<EOF;
---
qemu: qemu-system-x86_64
accel: hvf
cpu: host
machine: q35
keyboard: de

EOF
}

my ($hashref, $arrayref, $string);

unless(-f "$scriptpath/globals.yml") {
    usage("Error: $scriptpath/globals.yml: $!");
    exit(1);
}

unless(-r "$scriptpath/globals.yml") {
    usage("Error: $scriptpath/globals.yml: $!");
    exit(1);
}

($hashref, $arrayref, $string) = YAML::LoadFile("$scriptpath/globals.yml");

our $globals=$hashref;

#
# Parse and validate command line args
#

#my $data   = "file.dat";
#my $length = 24;
#my $verbose;
#GetOptions ("length=i" => \$length,    # numeric
#"file=s"   => \$data,      # string
#"verbose"  => \$verbose)   # flag
#or die("Error in command line arguments\n");

my $help;
GetOptions (
    ### "length=i" => \$length,    # numeric
    ### "file=s"   => \$data,      # string
    "help|h"  => \$help)
or die("Error in command line arguments\n");

if($help) {
    usage();
    exit(0);
}

if(scalar @ARGV<1) {
    usage("Usage: no action given!");
    exit(1);
}


my $action=shift @ARGV;

if($action eq "start") {
    do_start();
}
elsif($action eq "snapshot") {
    do_snapshot();
}
elsif($action eq "list") {
    do_list();
}
elsif($action eq "create") {
    do_create();
}
elsif($action eq "clone") {
    do_clone();
}
elsif($action eq "console") {
    do_console("console");
}
elsif($action eq "monitor") {
    do_console("monitor");
}
elsif($action eq "powerdown") {
    do_console("powerdown");
}
elsif($action eq "quit") {
    do_console("quit");
}
elsif($action eq "kill") {
    do_kill();
}
elsif($action eq "print-defaults") {
    do_print_defaults();
}
else {
    usage("Invalid action: $action");
    exit(1);
}

