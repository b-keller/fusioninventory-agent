package Ocsinventory::Agent::Targets;

use strict;
use warnings;

use Ocsinventory::Agent::Target;

use Data::Dumper;

sub new {
    my (undef, $params) = @_;

    my $self = {};

    my $config = $self->{config} = $params->{config};
    my $logger = $self->{logger} = $params->{logger};

    $self->{targets} = [];


    print Dumper($config->{server});

    bless $self;

    $self->initialise();

    return $self;
}

sub addTarget {
    my ($self, $params) = @_;

    my $logger = $self->{'logger'};

    $logger->fault("No target?!") unless $params->{'target'};

    push @{$self->{targets}}, $params->{'target'};

}

sub initialise {
    my ($self) = @_;

    my $config = $self->{config};
    my $logger = $self->{logger};

    if ($config->{'stdout'}) {
        my $target = new Ocsinventory::Agent::Target({
                'logger' => $logger,
                config => $config,
                'type' => 'stdout',
            });
        $self->addTarget({
                target => $target
            });
    }

    if ($config->{'local'}) {
        my $target = new Ocsinventory::Agent::Target({
                'config' => $config,
                'logger' => $logger,
                'type' => 'local',
                'path' => $config->{'local'}
            });
        $self->addTarget({
                target => $target
            });
    }

    foreach my $val (split(/;/, $config->{'server'})) {
        my $url;
        if ($val !~ /^http(|s):\/\//) {
            $logger->debug("the --server passed doesn't ".
                "have a protocle, ".
                "assume http as default");
            $url = "http://".$val.'/ocsinventory';
        } else {
            $url = $val;
        }
        my $target = new Ocsinventory::Agent::Target({
                'config' => $config,
                'logger' => $logger,
                'type' => 'server',
                'path' => $url
            });
        $self->addTarget({
                target => $target
            });
    }

    print Dumper($self);

}

1;
