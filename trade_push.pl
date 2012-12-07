#!/usr/bin/perl

use strict;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::PP;
use List::Util;

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my $body_name;
my $target_name;
my $ship_name = "^Food Swap";
my $cargo = "algae";
my $stay = 0;
my $debug = 0;
my $quiet = 0;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \$body_name,
  "target=s"    => \$target_name,
  "ship|name=s" => \$ship_name,
  "cargo=s"     => \$cargo,
  "stay"        => \$stay,
  "debug"       => \$debug,
  "quiet"       => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

die "Must specify body and target\n" unless $body_name && $target_name;

my $client = Client->new(config => $config_name);
my $planets = $client->empire_status->{planets};
my $body_id;
my $target_id;
for my $id (keys(%$planets)) {
  $body_id   = $id if $planets->{$id} =~ /$body_name/;
  $target_id = $id if $planets->{$id} =~ /$target_name/;
}
exit(1) if $quiet && (!$body_id || !$target_id);
die "No matching planet for name $body_name\n"   unless $body_id;
die "No matching planet for name $target_name\n" unless $target_id;

my $buildings = $client->body_buildings($body_id);
$body_name = $client->body_status($body_id)->{name};

my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

my $trade = (grep($_->{name} eq "Trade Ministry", @buildings))[0];
my $port  = (grep($_->{name} eq "Space Port",     @buildings))[0];

die "No Trade Ministry on $body_name\n" unless $trade;
die "No Space Port ". "on $body_name\n" unless $port;

my $ships = $client->port_all_ships($port->{id}, 1);
my $ship = (grep($_->{name} =~ /$ship_name/ && $_->{task} eq "Docked", @{$ships->{ships}}))[0];

exit(0) unless $ship;

my $items;
if ($cargo =~ /^\{/) {
  # e.g. --cargo '{"quantity":6,"type":"ship","name":"Probe 30","ship_type":"probe","hold_size":0,"berth_level":1,"speed":22550,"size":50000}'
  $cargo = decode_json($cargo);
  $items = [ map { { type => $_, quantity => $cargo->{$_} } } keys %$cargo ];
}
elsif ($cargo =~ /^\[/) {
  $items = decode_json($cargo);
}
elsif ($cargo eq "all") {
  my %avail;
  my $resources = $client->call(trade => get_stored_resources => $trade->{id});
  for my $res (keys %{$resources->{resources}}) {
    $avail{$res} = List::Util::max(0, $resources->{resources}{$res} - 100);
  }
  my $remain = $ship->{hold_size};
  my %sending;
  my @res = sort { $avail{$a} <=> $avail{$b} } grep { $avail{$_} } keys %avail;
  while (@res) {
    my $max = int($remain / @res);
    my $res = shift @res;
    $sending{$res} = List::Util::min($max, $avail{$res});
    $remain -= $sending{$res};
  }
  $items = [ map { { type => $_, quantity => $sending{$_} } } keys %sending ];
}
else {
  my $resources = $client->call(trade => get_stored_resources => $trade->{id});
  my $amount = List::Util::min($ship->{hold_size}, $resources->{resources}{$cargo});
  $items = [ { type => $cargo, quantity => $amount } ],
}

my $result = $client->trade_push(
  $trade->{id}, $target_id,
  $items,
  { ship_id => $ship->{id}, stay => $stay }
);

my $item_text = join(", ", map { "$_->{quantity} $_->{type}" } @$items);

emit("Sending $item_text to $planets->{$target_id} on $ship->{name}") if $result;

sub emit {
  my $message = shift;
  print Client::format_time(time())." $body_name: $message\n";
}
