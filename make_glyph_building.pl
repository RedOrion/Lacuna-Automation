#!/usr/bin/perl

use strict;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::PP;
use List::Util qw(min max sum first);

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my @body_name;
my $ship_name;
my $for_name;
my $equalize = 0;
my $debug = 0;
my $quiet = 0;
my $plan_count = 0;
my $plan_type = 0;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \@body_name,
  "type=s"      => \$plan_type,
  "count=i"     => \$plan_count,
  "for=s"       => \$for_name,
  "debug"       => \$debug,
  "quiet"       => \$quiet,
) or die "$0 --config=foo.json --body=Bar --type=Halls [--count=1] [--for=Baz]\n";

die "Must specify body\n" if $plan_count && !@body_name;

my %recipes = (
  'Algae Pond'                    => [ [ qw(uraninite methane) ] ],
  'Amalgus Meadow'                => [ [ qw(beryl trona) ] ],
  'Beeldeban Nest'                => [ [ qw(anthracite trona kerogen) ] ],
  'Black Hole Generator'          => [ [ qw(kerogen beryl anthracite monazite) ] ],
  'Citadel of Knope'              => [ [ qw(beryl sulfur monazite galena) ] ],
  'Crashed Ship Site'             => [ [ qw(monazite trona gold bauxite) ] ],
  'Denton Brambles'               => [ [ qw(rutile goethite) ] ],
  'Gas Giant Settlement Platform' => [ [ qw(sulfur methane galena anthracite) ] ],
  'Geo Thermal Vent'              => [ [ qw(chalcopyrite sulfur) ] ],
  "Gratch's Gauntlet"             => [ [ qw(chromite bauxite gold kerogen) ] ],
  'Halls of Vrbansk' => [
    [ qw(goethite halite gypsum trona) ],
    [ qw(gold anthracite uraninite bauxite) ],
    [ qw(kerogen methane sulfur zircon) ],
    [ qw(monazite fluorite beryl magnetite) ],
    [ qw(rutile chromite chalcopyrite galena) ],
  ],
  'Interdimensional Rift'         => [ [ qw(methane zircon fluorite) ] ],
  'Kalavian Ruins'                => [ [ qw(galena gold) ] ],
  'Lapis Forest'                  => [ [ qw(halite anthracite) ] ],
  'Library of Jith'               => [ [ qw(anthracite bauxite beryl chalcopyrite) ] ],
  'Malcud Field'                  => [ [ qw(fluorite kerogen) ] ],
  'Natural Spring'                => [ [ qw(magnetite halite) ] ],
  'Oracle of Anid'                => [ [ qw(gold uraninite bauxite goethite) ] ],
  'Pantheon of Hagness'           => [ [ qw(gypsum trona beryl anthracite) ] ],
  'Ravine'                        => [ [ qw(zircon methane galena fluorite) ] ],
  'Temple of the Drajilites'      => [ [ qw(kerogen rutile chromite chalcopyrite) ] ],
  'Terraforming Platform'         => [ [ qw(methane zircon magnetite beryl) ] ],
  'Volcano'                       => [ [ qw(magnetite uraninite) ] ],
);

die "Unknown building type: $plan_type\n" unless grep { $_ =~ /$plan_type/ } keys %recipes;

$plan_type = first { $_ =~ /$plan_type/ } keys %recipes;
my ($what, $of_whom) = split / of /, $plan_type, 2;
my $plan_plural = $what.($what =~ /s$/ ? '' : 's');
$plan_plural =~ s/ys$/ies/;
my @recipes = @{$recipes{$plan_type}};

my $client = Client->new(config => $config_name);
eval {
  warn "Getting empire status\n" if $debug;
  my $planets = $client->empire_status->{planets};

  my $for_id;
  if ($for_name =~ /^(trade|sst)$/i) {
    # Do nothing.
  }
  elsif ($for_name) {
    $for_id = (grep { $planets->{$_} =~ /$for_name/ } keys(%$planets))[0];
    die "No matching planet for name $for_name\n" if $for_name && !$for_id;
    $for_name = $planets->{$for_id};
  }

  push(@body_name, sort values(%$planets)) unless @body_name;
  warn "Looking at bodies ".join(", ", @body_name)."\n" if $debug;
  for my $body_name (@body_name) {
    eval {
      my $body_id;
      for my $id (keys(%$planets)) {
        $body_id = $id if $planets->{$id} =~ /$body_name/;
      }
      exit(1) if $quiet && !$body_id;
      die "No matching planet for name $body_name\n" unless $body_id;

      # get archaeology
      warn "Getting body buildings for $planets->{$body_id}\n" if $debug;
      my $buildings = $client->body_buildings($body_id);
      my @buildings = map { { %{$buildings->{buildings}{$_}}, id => $_ } } keys(%{$buildings->{buildings}});

      my $arch_id = (grep($_->{name} eq "Archaeology Ministry", @buildings))[0]{id};
      unless ($arch_id) {
        warn "No Archaeology Ministry on $planets->{$body_id}\n";
        next;
      }
      warn "Using Archaeology Ministry id $arch_id\n" if $debug;

      warn "Getting glyphs on $planets->{$body_id}\n" if $debug;
      my $glyphs = $client->call(archaeology => get_glyphs => $arch_id);
      unless ($glyphs->{glyphs}) {
        warn "No glyphs on $planets->{$body_id}\n";
        next;
      }

      my %glyphs = map { ($_, []) } map { @$_ } @recipes;
      for my $glyph (@{$glyphs->{glyphs}}) {
        push(@{$glyphs{$glyph->{type}}}, $glyph->{id});
      }

      my %extra;
      my %possible;
      for my $recipe (@recipes) {
        my $min = List::Util::min(map { scalar(@{$glyphs{$_}}) } @$recipe);
        $possible{$recipe} = $min;
        for my $glyph (@$recipe) {
          $extra{$glyph} = @{$glyphs{$glyph}} - $min;
        }
      }

      my $max_plans = List::Util::sum(values(%possible));
      print "Can make $max_plans $plan_plural with ".List::Util::sum(values(%extra))." unmatched glyphs on $planets->{$body_id}.\n";

      die "Insufficient glyphs to make $plan_count $plan_plural\n" if $max_plans < $plan_count;

      while ($max_plans > $plan_count) {
        for my $recipe (@recipes) {
          last if $max_plans <= $plan_count;
          if ($possible{$recipe}) { $possible{$recipe}--; $max_plans--; }
        }
      }

      for my $recipe (@recipes) {
        while ($possible{$recipe}--) {
          my @ids;
          for my $glyph (@$recipe) {
            push(@ids, pop(@{$glyphs{$glyph}}));
          }
          print "Making $plan_plural with ".join(", ", @$recipe).": ".join(", ", @ids)."\n";
          my $result = $client->call(archaeology => assemble_glyphs => $arch_id, [ @ids ]);
          print "Failed to make $plan_type!\n" if $result->{item_name} ne $plan_type;
        }
      }

      if ($for_name =~ /^sst$/i) {
        my $trade_id = (grep($_->{name} eq "Subspace Transporter", @buildings))[0]{id};
        unless ($trade_id) {
          warn "No Subspace Transporter on $planets->{$body_id}\n";
          next;
        }
        warn "Using Subspace Transporter id $trade_id\n" if $debug;

        my $plans = $client->call(transporter => get_plans => $trade_id);
        my $psize = $plans->{cargo_space_used_each};
        my @plans = grep { $_->{name} eq $plan_type } @{$plans->{plans}};
        $#plans = $plan_count - 1 if @plans > $plan_count;

        my $max = eval { $client->building_view(transporter => $trade_id)->{transport}{max} };
        unless ($max) {
          warn "Couldn't get max transport capacity of Subspace Transporter\n";
          next;
        }

        while (@plans) {
          my @items;
          push(@items, { type => "plan", plan_id => (shift(@plans))->{id} }) while @plans && @items < $max / $psize;
          print "Putting ".scalar(@items)." $plan_plural on the market for 1e.\n";
          $client->call(transporter => add_to_market => $trade_id, \@items, 1);
        }
      }
      elsif ($for_name) {
        my $trade_id = (grep($_->{name} eq "Trade Ministry", @buildings))[0]{id};
        unless ($trade_id) {
          warn "No Trade Ministry on $planets->{$body_id}\n";
          next;
        }
        warn "Using Trade Ministry id $trade_id\n" if $debug;

        my $plans = $client->call(trade => get_plans => $trade_id);
        my $psize = $plans->{cargo_space_used_each};
        my @plans = grep { $_->{name} eq $plan_type } @{$plans->{plans}};
        $#plans = $plan_count - 1 if @plans > $plan_count;

        my @ships = @{$client->call(trade => get_trade_ships => $trade_id, $for_id)->{ships}};
        # Avoid ships already allocated to trade routes
        @ships = grep { $_->{name} !~ /(Alpha|Beta|Gamma|Delta)$/ } @ships;

        $_->{plan_count} = int($_->{hold_size} / $psize) for @ships;

        # Choose fast ships sufficient to carry all the plans
        @ships = sort { $b->{speed} <=> $a->{speed} } @ships;
        my $top = 0;
        my $move_count = $ships[0]{plan_count};
        $move_count += $ships[++$top]{plan_count} while $top < $#ships && $move_count < $plan_count;
        $#ships = $top;
        print "Can only ship $move_count $plan_plural. :-(\n" if $move_count < $plan_count;

        # Choose the big ships from among the sufficient chosen ships (and free up any extra fast small ships)
        @ships = sort { $b->{hold_size} <=> $a->{hold_size} } @ships;
        $top = 0;
        $move_count = $ships[0]{plan_count};
        $move_count += $ships[++$top]{plan_count} while $top < $#ships && $move_count < $plan_count;
        $#ships = $top;

        for my $ship (@ships) {
          my @items;
          push(@items, { type => "plan", plan_id => (shift(@plans))->{id} }) while @plans && @items < $ship->{plan_count};
          if ($for_name =~ /^trade$/i) {
            print "Putting ".scalar(@items)." $plan_plural on the market for 1e with $ship->{name}.\n";
            $client->call(trade => add_to_market => $trade_id, \@items, 1, { ship_id => $ship->{id} });
          }
          else {
            print "Pushing ".scalar(@items)." $plan_plural to $for_name on $ship->{name}.\n";
            $client->trade_push($trade_id, $for_id, \@items, { ship_id => $ship->{id}, stay => 0 });
          }
        }
      }
    }
  }
};
