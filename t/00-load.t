#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Bot::BasicBot::Pluggable::Module::Quote' ) || print "Bail out!\n";
}

diag( "Testing Bot::BasicBot::Pluggable::Module::Quote $Bot::BasicBot::Pluggable::Module::Quote::VERSION, Perl $], $^X" );
