#!/usr/bin/env perl

# Markus.Mueller@consol.de, 2014
# VMWare cmds for the monitoring build environment

use warnings;
use strict;
use VMware::VIRuntime;

use Data::Dumper;
$Data::Dumper::Indent=1;

use Config::General;

# If you get errors connecting to vcenter as the following:
# Server version unavailable at 'https://<hostname>:443/sdk/vimService.wsdl' at /path/to/VMware/VICommon.pm line 545.
# Try this:
#$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;

###########
# Config
sub merge_config {
    my ($cfg, $cfg_file) = @_;
    return $cfg unless ( -r $cfg_file );

    # Load the configuration file
    my $config_general = new Config::General($cfg_file)
        or die "ERROR: parsing the config in \"$cfg_file\": $@\n";
    my %local_cfg = $config_general->getall;

    # merge locally made config with defaults
    for my $key ( keys %local_cfg ) {
        if(defined $cfg->{$key} and ref $cfg->{$key} eq 'HASH') {
            $cfg->{$key} = { %{$cfg->{$key}}, %{$local_cfg{$key}} };
        } else {
            $cfg->{$key} = $local_cfg{$key};
        }
    }
    return $cfg;
}

sub get_config {
    # defaults
    my $cfg = {
        # this value cannot be overridden by the config file:
        'cfg_file'              => $ENV{'HOME'}. '/.vmware_cmd.conf',
        'cfg_file_local'        => $ENV{'HOME'}. '/.vmware_cmd_local.conf',
        # these values can be overridden by the config file:
        'build_master'          => `hostname`,
        'poweroffmaxseconds'    => 15,
        'debug_log'             => '/tmp/vmware_cmd_poweroff.log',
    };

    $cfg = merge_config($cfg, $cfg->{'cfg_file'});
    $cfg = merge_config($cfg, $cfg->{'cfg_file_local'});

    if( ! defined $cfg->{'build_vm_prefix'} ){
        die("ERROR: Please define build_vm_prefix in $cfg->{'cfg_file'}" );
    } elsif( ! defined $cfg->{'vcenter_username'}
        or ! defined $cfg->{'vcenter_password'}
        or ! defined $cfg->{'vcenter_url'}
    ){
        printf("Consider setting user, pass and url in $cfg->{'cfg_file'}.\n");
    }
    return $cfg;
}

my $cfg = get_config();


###########
# cmdline opts
my %opts = (
    'delay' => {
        type => "=i",
        help => "delay execution of cmd for <seconds>",
        required => 0,
    },
    'list' => {
        type => "",
        help => "List Build VMs (without master).",
        required => 0,
    },
    'list_running' => {
        type => "",
        help => "List running Build VMs (without master).",
        required => 0,
    },
    'restore' => {
        type => "=s",
        help => "restore <vmname> to newest snapshot",
        required => 0,
    },
    'poweroff' => {
        type => "=s",
        help => "poweroff <vmname>",
        required => 0,
    },
    'poweron' => {
        type => "=s",
        help => "poweron <vmname>",
        required => 0,
    },
    'status' => {
        type => "",
        help => "list vms with vm-powerstate",
        required => 0,
    },
    'all' => {
        type => "",
        help => "List all VMs, not only build-vms",
        required => 0,
    },
);


# read/validate options
# ->validate causes to ask for username and password if $ENV{VI_USERNAME} and
# $ENV{VI_PASSPWORD} are not set..
# if you don't validate the --help will not work however
# TODO
$ENV{VI_USERNAME} = $cfg->{'vcenter_username'};
$ENV{VI_PASSWORD} = $cfg->{'vcenter_password'};
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

# login vcenter
my $vim = Vim::login(
    service_url => $cfg->{'vcenter_url'},
    username    => $cfg->{'vcenter_username'},
    password    => $cfg->{'vcenter_password'},
);

if ( defined Opts::get_option('delay') ){
  sleep Opts::get_option('delay');
}


if ( defined Opts::get_option('list') ){
        my $all = Opts::get_option('all');
        my $vm_views = $vim->find_entity_views(
            view_type => 'VirtualMachine',
        );
        foreach my $vm ( @$vm_views ){
            my $name = $vm->name;
            if ( $all || $name =~ m/$cfg->{'build_vm_prefix'}.*/ ){
                my $status = sprintf("%-35s", $vm->name) . $vm->runtime->powerState->val . "\n";
                $status =~ s/poweredOn/running/;
                $status =~ s/poweredOff/stopped/;
                print $status unless ( $name eq $cfg->{'build_master'} and !$all );
            }
        }
}

if ( defined Opts::get_option('list_running') ){
    foreach my $powerstate ( 'poweredOn' ){
        my $vm_views = $vim->find_entity_views(
            view_type => 'VirtualMachine',
            filter => {
                # does not work as I expected.. workaround below
                #'guest.guestFullName' => "$build_vm_prefix.*",
                'runtime.powerState' => $powerstate,
        });
        foreach my $vm ( @$vm_views ){
            my $name = $vm->name;
            if ( $name =~ m/$cfg->{'build_vm_prefix'}.*/ ){
                print $vm->name . "\n" unless ( $name eq $cfg->{'build_master'} );
            }
        }
    }
}


# restore latest snapshot
if ( defined Opts::get_option('restore') ){
    my $name = Opts::get_option('restore');
    $name = expand_name($name);
    my $vm = get_vm($name);
    my $current_snap = $vm->snapshot->currentSnapshot->value;
    my $powerstate = $vm->runtime->powerState->val;
    if ( $powerstate eq 'poweredOn' ){
        print "VM is running - initiating poweroff\n";
        $vm->PowerOffVM_Task;
        my $i=0;
        my $notok=1;
        while ( $i < $cfg->{'poweroffmaxseconds'} ){
            $i++;
            next unless ( $notok );
            sleep 1;
            $vm = get_vm($name);
            $powerstate = $vm->runtime->powerState->val;
            if ( $powerstate ne 'poweredOff' ){
                $notok = 1;
            } else {
                $notok = 0;
            }
        }
        if ( $notok ){
            die "Poweroff failed - increase poweroffmaxseconds or fix s.th.\n";
        }
    } elsif ( $powerstate eq 'poweredOff' ){
    } else {
        die "Unexpecter Powerstate for vm: $powerstate . Fix this script.";
    }
    if ( $powerstate eq "poweredOff" ){
        print "reverting to Snapshot $current_snap.\n";
        my $runstate = $vm->RevertToCurrentSnapshot_Task;
    }
}

if ( defined Opts::get_option('poweron') ){
    my $name = Opts::get_option('poweron');
    my $orig = $name;
    my $vm;
    eval {
        $name = expand_name($name);
        $vm   = get_vm($name);
    };
    if($@) {
        $vm   = get_vm($orig);
        $name = $orig;
    }
    my $powerstate = $vm->runtime->powerState->val;
    if ( $powerstate eq 'poweredOff' ){
        $vm->PowerOnVM_Task;
        print "started $name\n";
        post_vm_start($name);
    } elsif ( $powerstate eq 'poweredOn' ){
        print "already running\n";
    } else {
        die "Unexpecter Powerstate for vm: $powerstate . Fix this script.";
    }
}

# TODO: try soft shutdown via VMWare Tools first?
if ( defined Opts::get_option('poweroff') ){
    my $name = Opts::get_option('poweroff');
    $name = expand_name($name);
    my($vm, $powerstate);
    eval {
        $vm = get_vm($name);
        $powerstate = $vm->runtime->powerState->val;
    };
    if($@) { # do some debug logging
        open(my $fh, '>>', $cfg->{'debug_log'});
        print $fh '**************', "\n";
        print $fh 'time: ', scalar localtime, "\n";
        print $fh 'name: ', $name, "\n";
        print $fh 'state: ', ($powerstate || 'unknown'), "\n";
        print $fh 'delay: ', Opts::get_option('delay'), "\n" if Opts::get_option('delay');
        print $fh 'error: ', $@, "\n";
        close($fh);
        print 'error: ', $@;
        exit 1;
    }

    if ( $powerstate eq 'poweredOn' ){
        $vm->PowerOffVM_Task;
    } elsif ( $powerstate eq 'poweredOff' ){
    } else {
        $vm->PowerOffVM_Task; # try it anyway
        die "Unexpecter Powerstate for vm: $powerstate . Fix this script.";
    }
}

# logout
$vim->logout();

############
# helper subs

# the find_entity_filter needs fixing...
# workaround:
sub get_vm {
    my $vm_name = shift;
    if( $vm_name =~ /^$cfg->{'build_master'}$/ ){
        die("Error: I promised not to operate on the build_master.");
    }
    # allow shortcuts
    foreach my $powerstate ( 'On', 'Off' ){
        my $vm_views = $vim->find_entity_views(
            view_type => 'VirtualMachine',
            filter => {
                'runtime.powerState' => 'powered' . $powerstate,
        });
        foreach my $vm ( @$vm_views ){
            my $name = $vm->name;
            if ( $name =~ m/^$vm_name$/){
                return $vm;
            }
        }
    }
    die "VM $vm_name not found! exiting.\n";
    exit 2;
}


sub expand_name {
    my $name = shift;
    if( defined $cfg->{'expand_conf'}->{'postfix'} ){

        if( $name !~ m/$cfg->{'expand_conf'}->{'postfix'}$/ ){
            if( defined $cfg->{'expand_conf'}->{'arch_types'} ){
                if($name !~ m/$cfg->{'expand_conf'}->{'arch_types'}$/) {
                    if( defined $cfg->{'expand_conf'}->{'arch_default'} ){
                        $name = $name.$cfg->{'expand_conf'}->{'arch_default'}
                    }
                }
            }
            $name = $name.$cfg->{'expand_conf'}->{'postfix'};
        }
    }
    if( defined $cfg->{'expand_conf'}->{'prefix'} ){
        if($name !~ m/^$cfg->{'expand_conf'}->{'prefix'}/) {
            $name = $cfg->{'expand_conf'}->{'prefix'}.$name;
        }
    }
    return $name;
}


sub post_vm_start {
    my $name = shift;
    my $cmd = $cfg->{'post_vm_start_cmd'};
    if( defined $cmd and -e $cmd and -x $cmd ){
        system(sprintf("%s %s &", $cmd,$name));
    }
}

