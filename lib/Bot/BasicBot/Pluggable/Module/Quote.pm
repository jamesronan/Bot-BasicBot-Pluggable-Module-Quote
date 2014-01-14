package Bot::BasicBot::Pluggable::Module::Quote;

use strict;
no warnings;
use feature 'switch';
use base    'Bot::BasicBot::Pluggable::Module';
use utf8;

use LWP::Simple;
use HTML::TreeBuilder;

=head1 NAME

Bot::BasicBot::Pluggable::Module::Quote - Misquotage FTW!

=head1 DESCRIPTION

Allows users to add, delete and score quotes from an IRC channel.

Basically just a stupid childish thing to do in an IRC channel. Mis-quote
what was said, up and down-vote quotes, recall them etc.

It currently stores quotes in a local MySQL DB.
TODO: add internal bot store support and flexible DB drivers config.

=head1 CONFIG

A config file 'quote.conf' will need to be created and located in the same
directory as your bot script.
TODO: Make the config file name a parameter of the module.

This config file should contain a perl hashref with the following format:
TODO add Config::Any to this

{
    # DB Connection details for the Quote DB this should probably also have
    # a db_type => 'internal|external' option to use the bot store if required
    db => {
        host     => 'localhost',
        db       => 'irc',       # Your DB name here.
        user     => 'ircbots',   # Your chosen DB username here.
        password => 'wibble',    # Your chosen DB password
        # TODO: driver should be an option.
    },

    # This map allows you to specify which other channel quotes get pulled in
    # by a channel (For channel renames/extra channels)
    cross_channel_map => {
        '#channel1'   => [ qw( #channel2 #channel3 ) ],
        '#channel4'   => [ qw( #channel2 ) ],
    },
}

=cut

my $capture_regex = qr/
    ^
    !(\w+)                       # Any pling command ...
    (?:                          # optionally followed by...
        \s                       # a space and...
        (.+?) \s? (\-\-|\+\+)?   # some criteria and maybe inc|dec operator
    )?
    $
/x;
my $config_file = 'quote.conf';

sub help {
    return <<HELP
Allows users to add, delete and score quotes from an IRC channel.

Commands:
    !addquote <quote> - Adds a new quote to the DB.
    !delquote <id>    - Deletes the quote identified by quoteid. Quotes can
                        only be deleted by the person that created it.
    !q, !quote        - Selects a single quote from the DB at random.
    !q <quoteid>      - Selects a specific quote from the DB.
    !q <quoteid> ++   - Increments the score of the given quote.
    !q <quoteid> --   - Decrements the score of the given quote.
    !q <term>         - Searches the DB for a quote containing <term>.
    !spammenow,
    !encyclopedia     - Returns a random selection of quotes.
    !encyclopedia <term>
    !spammenow <term> - Returns a random selection of quotes containing <term>.
    !topq, !topquote,
    !top, !topquotes  - Returns the 10 highest ranked quotes.
    !top <term>       - Returns the 10 highest ranked quotes containing <term>.
    !last, !lastq,
    !lastest, !laatestq,
    !lastestquotes    - Returns the last 5 quotes added.
    !last(etc) <term> - Returns the last 5 quotes containing <term>.
    !butchered        - Returns a the most 'butchered' quotes.
    !innuendo         - Returns an innuendo line.
    !tagline,
    !funnyquote       - Returns a Tagline from the Taglines DB Table.

HELP
}

sub init {
    my ($self) = @_;
    $self->conf($config_file);
}

sub said {
    my ($self, $message, $priority) = @_;

    return unless $priority == 2;

    my ($action, $criteria, $change) = $message->{body} =~ $capture_regex;
    return unless $action;

    # We have a !command, see if it's one we implement here.
    my %actions = (
        q            => 'single_quote',
        quote        => 'single_quote',
        top          => 'top_quotes',
        topq         => 'top_quotes',
        topquote     => 'top_quotes',
        topquotes    => 'top_quotes',
        last         => 'latest_quotes',
        lastq        => 'latest_quotes',
        latest       => 'latest_quotes',
        latestq      => 'latest_quotes',
        latestquotes => 'latest_quotes',
        spammenow    => 'multi_quotes',
        encyclopedia => 'multi_quotes',
        butchered    => 'butchered_quotes',
        addquote     => 'add_quote',
        delquote     => 'delete_quote',
        innuendo     => 'innuendo',
        tagline      => 'tagline',
        funnyquote   => 'tagline',
    );
    return unless (grep { $_ eq $action } keys %actions);

    # Dispatch the appropriate sub to hand back the quote.
    my $subname = $actions{$action};
    return $self->$subname(
        message  => $message,
        criteria => $criteria,
        change   => $change
    );
}


# Dispatch routines

sub single_quote {
    my ($self, %params) = @_;

    if (   $params{change}
        && $params{criteria} =~ /\d+/ )
    {
        return $self->score_change(%params);
    }

    return $self->get_quotes(
        message  => $params{message},
        criteria => $params{criteria},
        qty      => 1,
    );
}

sub multi_quotes {
    my ($self, %params) = @_;

    return $self->get_quotes(
        message  => $params{message},
        criteria => $params{criteria},
        qty      => 10,
    );
}

sub top_quotes {
    my ($self, %params) = @_;

    return $self->get_quotes(
        message  => $params{message},
        criteria => $params{criteria},
        qty      => 10,
        order    => 'score',
    );
}

sub latest_quotes {
    my ($self, %params) = @_;

    return $self->get_quotes(
        message  => $params{message},
        criteria => $params{criteria},
        qty      => 5,
        order    => 'id',
    );
}

sub butchered_quotes {
    my ($self, %params) = @_;

    return $self->get_quotes(
        message  => $params{message},
        criteria => $params{criteria},
        qty      => 10,
        order    => 'butchered',
    );
}

sub add_quote {
    my ($self, %params) = @_;

    my $message = $params{message};
    my $quote   = $message->{body};
    $quote =~ s/^!addquote\s//;
    utf8::encode($quote);

    # Silly Mac users and their fancy ellipses:
    $quote =~ s/\x{2026}/.../g;

    my @bind_params = ($message->{who}, $message->{channel}, $quote);
    my $sth = $self->dbh->prepare(<<INSERTSQL) or warn "SQL Error: $!";
INSERT INTO quotes (submitter, channel, quote, submitted)
    VALUES ( ?, ?, ?, NOW() );
INSERTSQL

    if (   !$sth
        || !$sth->execute(@bind_params) )
    {
        warn "Couldn't INSERT quote. Fnar!";
        return "Unable to 'insert' quote, Fnar!";
    }

    # Getting here means that the quote was added... get it's ID.
    my $quotedata = $self->get_quotes(
        message  => $message,
        order    => 'id',
        qty      => 1,
        dataonly => 1,
    );

    return "Quote $quotedata->{id} added";

}

sub delete_quote {
    my ($self, %params) = @_;

    my $quoteid = $params{criteria};

    # We obviously need something that looks like a quote ID.
    return "Huh? '$quoteid' doesn't look like a Quote ID"
        if $quoteid !~ /^\d+$/;

    # Get the info about the quote.
    my $quotedata = $self->get_quotes(
        message  => $params{message},
        criteria => $quoteid,
        qty      => 1,
        dataonly => 1,
    );

    # If get_quotes wibbled... return the wibble.
    return $quotedata if ref($quotedata) ne 'HASH';

    # People can only delete their own quotes...
    my $who       = $params{message}->{who};
    my $submitter = $quotedata->{submitter};
    if ( $submitter ne $who ) {
        return "$who: You can only delete your own quotes, "
            . "that one was submitted by $submitter. Sorry.";
    }

    # If we're here, it's a quote, and it's theirs. Delete away...
    my $sth = $self->dbh->prepare('DELETE FROM quotes WHERE id = ? LIMIT 1')
      or warn "SQL Error: $!";
    if (   !$sth
        || !$sth->execute($quoteid) )
    {
        return "I was unable to delete quote $quoteid, sorry";
    }

    return "Quote $quoteid deleted!";

}

sub tagline {
    my ($self, %params) = @_;

    my $sth = $self->dbh->prepare(<<TAGLINESQL) or warn "SQL Error: $!";
SELECT Tagline FROM Taglines ORDER BY RAND() LIMIT 1
TAGLINESQL

    my $tagline;
    if (   !$sth
        || !$sth->execute() )
    {
        return "Unable to retrieve a Tagline from the DB :(";
    }

    my ($tagline) = $sth->fetchrow_array;
    if (!$tagline) {
        return "There doesn't appear to be any taglines in the DB";
    }

    return $tagline;

}

sub innuendo {
    my ($self, %params) = @_;

    my $html = LWP::Simple::get("http://walkingdead.net/perl/euphemism");
    my $tree = HTML::TreeBuilder->new_from_content($html)
        or return "The site I get innuendo from couldn't give me one!";

    # the content we're interested in is inside the first TD:
    return $tree->look_down('_tag', 'td')->as_text;

}



sub get_quotes {
    my ($self, %params) = @_;

    my ($quoteid, $search_term, @bind_params);
    my $channel   = $params{message}->{channel};
    my $stringify = $params{stringify};

    # First off, to start constructing the WHERE we need to check if this
    # channel is in the cross channel map, if it is, we add the list of
    # channels to pull for, if not, just this channel.
    my $where_clause = "WHERE ";
    my $cross_channel_map = $self->conf->{cross_channel_map};

    if (grep { $_ eq $channel } keys %$cross_channel_map) {

        # OK, we're in the cross channel map, so add the other channels
        # to the WHERE
        push @bind_params, @{ $cross_channel_map->{$channel} }, $channel;
        my $placeholders = '?,' x scalar @bind_params;
        $placeholders =~ s/,$//;
        $where_clause .= "channel IN ($placeholders) ";

    } else {
        push @bind_params, $channel;
        $where_clause .= "channel = ? ";
    }

    # Now add any criteria we were given.
    given ($params{criteria}) {
        when (/^ ( \d+ ) $/x) {
            push @bind_params, $1;
            $where_clause .= "AND id = ? ";
        }
        when (/^ ( (?: \w+ \s? )+ ) $/x) {
            push @bind_params, $1;
            $where_clause .= "AND quote rlike ? ";
        }
    }

    # For the order, we either want it by score (ranked) or random
    my $order;
    given ($params{order}) {
        when ('butchered') {
            $order = "( LENGTH(quote) - LENGTH( REPLACE(quote, '.','') ) )"
                   . " / LENGTH(quote) DESC";
        }
        when (/^(\w+)$/)   { $order = "$1 DESC" }
        default            { $order = 'RAND()'  }
    }

    # Work out how many we want, default to 1
    my $quantity = $params{qty} // 1;

    # Construct our SQL statement.
    my $sth = $self->dbh->prepare(<<SQL) or warn "SQL Error $!";
SELECT
    id, quote, score, channel, submitter,
    DATE_FORMAT(submitted, '%Y/%m/%d') as submitted
FROM
    quotes
$where_clause
ORDER BY $order
LIMIT
    $quantity
SQL

    if (!$sth->execute(@bind_params)) {
        return ($stringify) ? 'Unable to retrieve quote(s)' : {};
    }

    my @quotes;
    while (my $row = $sth->fetchrow_hashref) {
        push @quotes, $row;
    }

    # If they wanted the data, rather than the pretty string version, give 'em
    # it.  If they only wanted the 1 return just the single hashref.
    if ($params{dataonly}) {
        return ($quantity == 1) ? shift @quotes : @quotes;
    }

    # The default is to return pretty, striaght-to-channel strings, so format a
    # a nice blob of text to hand back - If there were quotes of course.
    if (!@quotes) {
        if ($params{criteria} =~ /^\d+$/) {
            return "Sorry, quote ID $params{criteria} not found";
        } else {
            return "Sorry, I couldn't find anything containing "
                . "'$params{criteria}'";
        }
    }

    my @pretty_quotes;
    for my $quote (@quotes) {
	utf8::decode($quote->{quote});
        my $extra_info = " (added " . (
            $quote->{submitter}
                ? sprintf("%s by %s ", @$quote{qw(submitted submitter)})
                : ""
            ) . "in $quote->{channel})";

        push @pretty_quotes,
            "Quote: $quote->{id} (score: $quote->{score}) $quote->{quote}"
            . $extra_info;
    }
    return join "\n", @pretty_quotes;

}


sub score_change {
    my ($self, %params) = @_;

    my $quoteid = $params{criteria};
    my $scorechange =
        ( $params{change} =~ /\-\-/ ) ? -1
      : ( $params{change} =~ /\+\+/ ) ? +1
      :                                 undef;

    return unless $scorechange;

    my $sth = $self->dbh->prepare(<<QUERY) or warn "SQL Error: $!";
UPDATE quotes SET score = score + ? WHERE id = ?
QUERY
    if (!$sth->execute($scorechange, $quoteid)) {
        return "Unable to update quote for Quote #$quoteid";
    }

    # If we updated it we need to grab the quote and output it's score.
    my $quotedata = $self->get_quotes(
        message  => $params{message},
        criteria => $quoteid,
        dataonly => 1,
    );

    return "Quote $quoteid updated: score now $quotedata->{score}";

}


sub conf {
    my ($self, $configuration_file) = @_;

    if (   !$self->{conf}
        && !$configuration_file )
    {
        die "No config exists. Please specify a config file in the init sub";
    }

    if ($configuration_file) {
        # TODO: Add some file fingerprint checking so changes to the config
        #       don't require a restart.
        if (   !-e $configuration_file
            || !-f $configuration_file )
        {
            die "Unable to find configuration file!";
        }
        $self->{conf} = do $configuration_file;
    }

    return $self->{conf};
}


sub dbh {
    my ($self) = @_;

    # If we have an existsing DB handle, check that it is responsive.
    if ($self->{dbh}) {
        my $sth = $self->{dbh}->prepare('SELECT 1');
        if (   !$sth
            || !$sth->execute) {
            delete $self->{dbh};
        }
    }

    return $self->{dbh} //= $self->_new_dbh;
}

# The DB config is stored in a perl hash ref in a separate file... so grab that
# and create a DBH

sub _new_dbh {
    my ($self) = @_;

    my $dbconf = $self->conf->{db};
    warn "No config file (db config) for " . ref($self) if !$dbconf;

    return DBI->connect("dbi:mysql:$dbconf->{db}:$dbconf->{host}",
        $dbconf->{user}, $dbconf->{password} )
      or die "Unable to obtain a DB connection.";
}

=head1 AUTHOR

James Ronan, C<< <jamesr at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-bot-basicbot-pluggable-module-uk2 at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Bot-BasicBot-Pluggable-Module-UK2>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Bot::BasicBot::Pluggable::Module::Quote


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Bot-BasicBot-Pluggable-Module-Quote>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Bot-BasicBot-Pluggable-Module-Quote>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Bot-BasicBot-Pluggable-Module-Quote>

=item * Search CPAN

L<http://search.cpan.org/dist/Bot-BasicBot-Pluggable-Module-Quote/>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2014 James Ronan.

This program is released under the following license: GPL

=cut

1;

