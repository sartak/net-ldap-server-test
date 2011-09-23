package Net::LDAP::Server::Test;

use warnings;
use strict;
use Carp;
use IO::Select;
use IO::Socket;
use Data::Dump ();

our $VERSION = '0.12';

=head1 NAME

Net::LDAP::Server::Test - test Net::LDAP code

=head1 SYNOPSIS

    use Test::More tests => 10;
    use Net::LDAP::Server::Test;
    
    ok( my $server = Net::LDAP::Server::Test->new(8080), 
            "test LDAP server spawned");
    
    # connect to port 8080 with your Net::LDAP code.
    ok(my $ldap = Net::LDAP->new( 'localhost', port => 8080 ),
             "new LDAP connection" );
             
    # ... test stuff with $ldap ...
    
    # server will exit when you call final LDAP unbind().
    ok($ldap->unbind(), "LDAP server unbound");

=head1 DESCRIPTION

Now you can test your Net::LDAP code without having a real
LDAP server available.

=head1 METHODS

Only one user-level method is implemented: new().

=cut

{

    package    # fool Pause
        MyLDAPServer;

    use strict;
    use warnings;
    use Carp;
    use Net::LDAP::Constant qw(
        LDAP_SUCCESS
        LDAP_CONTROL_PAGED
        LDAP_OPERATIONS_ERROR
        LDAP_UNWILLING_TO_PERFORM
    );
    use Net::LDAP::Entry;
    use Net::LDAP::Filter;
    use Net::LDAP::FilterMatch;
    use Net::LDAP::Control;
    use Net::LDAP::ASN qw(LDAPRequest LDAPResponse);
    use Convert::ASN1 qw(asn_read);

    use base 'Net::LDAP::Server';
    use fields qw( _flags );

    use constant RESULT_OK => {
        'matchedDN'    => '',
        'errorMessage' => '',
        'resultCode'   => LDAP_SUCCESS
    };

    our %Data;    # package data lasts as long as $$ does.
    our $Cookies = 0;
    our %Searches;

    # constructor
    sub new {
        my ( $class, $sock, %args ) = @_;
        my $self = $class->SUPER::new($sock);
        warn sprintf "Accepted connection from: %s\n", $sock->peerhost();
        $self->{_flags} = \%args;
        return $self;
    }

    sub unbind {
        my $self    = shift;
        my $reqData = shift;
        return RESULT_OK;
    }

    # the bind operation
    sub bind {
        my $self    = shift;
        my $reqData = shift;
        return RESULT_OK;
    }

    # the search operation
    sub search {
        my $self = shift;

        if ( defined $self->{_flags}->{data} ) {
            return $self->_search_user_supplied_data(@_);
        }
        elsif ( defined $self->{_flags}->{auto_schema} ) {
            return $self->_search_auto_schema_data(@_);
        }
        else {
            return $self->_search_default_test_data(@_);
        }
    }

    sub _search_user_supplied_data {
        my ( $self, $reqData ) = @_;

        # TODO??

        #warn 'SEARCH USER DATA: ' . Data::Dump::dump \@_;
        return RESULT_OK, @{ $self->{_flags}->{data} };
    }

    sub _search_auto_schema_data {
        my ( $self, $reqData, $reqMsg ) = @_;

        #warn 'SEARCH SCHEMA: ' . Data::Dump::dump \@_;

        my @results;
        my $base    = $reqData->{baseObject};
        my $scope   = $reqData->{scope} || 'sub';
        my @filters = ();

        if ( $scope ne 'base' ) {
            if ( exists $reqData->{filter} ) {

                push( @filters,
                    bless( $reqData->{filter}, 'Net::LDAP::Filter' ) );

            }
        }

        #warn "stored Data: " . Data::Dump::dump \%Data;
        #warn "searching for " . Data::Dump::dump \@filters;

        # support paged results
        my ( $page_size, $cookie, $controls, $offset );
        if ( exists $reqMsg->{controls} ) {
            for my $control ( @{ $reqMsg->{controls} } ) {

                if ( $ENV{LDAP_DEBUG} ) {
                    warn "control: " . Data::Dump::dump($control) . "\n";
                }

                if ( $control->{type} eq LDAP_CONTROL_PAGED ) {
                    my $asn = Net::LDAP::Control->from_asn($control);

                    if ( $ENV{LDAP_DEBUG} ) {
                        warn "asn: " . Data::Dump::dump($asn) . "\n";
                    }
                    $page_size = $asn->size;

                    if ( $ENV{LDAP_DEBUG} ) {
                        warn "size   == $page_size";
                        warn "cookie == " . $asn->cookie;
                    }

                   # assign a cookie if this is the first page of paged search
                    if ( !$asn->cookie ) {
                        $asn->cookie( ++$Cookies );
                        $asn->value;    # IMPORTANT!! encode value with cookie

                        if ( $ENV{LDAP_DEBUG} ) {
                            warn "no cookie assigned. setting to $Cookies";
                        }

                        # keep track of offset
                        $Searches{ $asn->cookie } = 0;
                    }

                    $offset = $Searches{ $asn->cookie };
                    $cookie = $asn->cookie;

                    push( @$controls, $asn );
                }
            }
        }

        # loop over all keys looking for match
        # we sort in order for paged control to work
    ENTRY: for my $dn ( sort keys %Data ) {

            next unless $dn =~ m/$base$/;

            if ( $scope eq 'base' ) {
                next unless $dn eq $base;
            }
            elsif ( $scope eq 'one' ) {
                next unless $dn =~ m/^(\w+=\w+,)?$base$/;
            }

            my $entry = $Data{$dn};

            #warn "trying to match $dn : " . Data::Dump::dump $entry;

            my $match = 0;
            for my $filter (@filters) {

                if ( $filter->match($entry) ) {

                    #warn "$f matches entry $dn";
                    $match++;
                }
            }

            #warn "matched $match";
            if ( $match == scalar(@filters) ) {    # or $dn eq $base ) {

                # clone the entry so that client cannot modify %Data
                push( @results, $entry->clone );

            }
        }

        # for paged results we find everything then take a slice.
        # this is less how a Real Server would do it but does
        # work for the simple case where we want to make sure our offset
        # and page size are accurate and we're not returning the same results
        # in multiple pages.
        # the $page_size -1 is because we're zero-based.

        my $total_found = scalar(@results);
        if ( $ENV{LDAP_DEBUG} ) {
            warn "found $total_found total results for filters:"
                . Data::Dump::dump( \@filters );

            #warn Data::Dump::dump( \@results );
            if ($page_size) {
                warn "page_size == $page_size  offset == $offset\n";
            }
        }

        if ( $page_size && $offset > $#results ) {

            if ( $ENV{LDAP_DEBUG} ) {
                warn "exceeded end of results\n";
            }
            @results = ();

            # IMPORTANT!! must set pager cookie to false
            # to indicate no more results
            for my $control (@$controls) {
                if ( $control->isa('Net::LDAP::Control::Paged') ) {
                    $control->cookie(undef);
                    $control->value;    # IMPORTANT!! re-encode
                }
            }
        }
        elsif ( $page_size && @results ) {

            my $limit = $offset + $page_size - 1;
            if ( $limit > $#results ) {
                $limit = $#results;
            }

            if ( $ENV{LDAP_DEBUG} ) {
                warn "slice \@results[ $offset .. $limit ]\n";
            }
            @results = @results[ $offset .. $limit ];

            # update our global marker
            $Searches{$cookie} = $limit + 1;

            if ( $ENV{LDAP_DEBUG} ) {
                warn "returning " . scalar(@results) . " total results\n";
                warn "next offset start is $Searches{$cookie}\n";

                #warn Data::Dump::dump( \@results );
            }

        }

        # special case. client is telling server to abort.
        elsif ( defined $page_size && $page_size == 0 ) {

            @results = ();

        }

        #warn "search results for " . Data::Dump::dump($reqData) . "\n: "
        # . Data::Dump::dump \@results;

        return ( RESULT_OK, \@results, $controls );

    }

    sub _search_default_test_data {
        my ( $self, $reqData ) = @_;

        #warn 'SEARCH DEFAULT: ' . Data::Dump::dump \@_;

        my $base = $reqData->{'baseObject'};

        # plain die if dn contains 'dying'
        die("panic") if $base =~ /dying/;

        # return a correct LDAPresult, but an invalid entry
        return RESULT_OK, { test => 1 } if $base =~ /invalid entry/;

        # return an invalid LDAPresult
        return { test => 1 } if $base =~ /invalid result/;

        my @entries;
        if ( $reqData->{'scope'} ) {

            # onelevel or subtree
            for ( my $i = 1; $i < 11; $i++ ) {
                my $dn    = "ou=test $i,$base";
                my $entry = Net::LDAP::Entry->new;
                $entry->dn($dn);
                $entry->add(
                    dn => $dn,
                    sn => 'value1',
                    cn => [qw(value1 value2)]
                );
                push @entries, $entry;
            }

            my $entry1 = Net::LDAP::Entry->new;
            $entry1->dn("cn=dying entry,$base");
            $entry1->add(
                cn => 'dying entry',
                description =>
                    'This entry will result in a dying error when queried'
            );
            push @entries, $entry1;

            my $entry2 = Net::LDAP::Entry->new;
            $entry2->dn("cn=invalid entry,$base");
            $entry2->add(
                cn => 'invalid entry',
                description =>
                    'This entry will result in ASN1 error when queried'
            );
            push( @entries, $entry2 );

            my $entry3 = Net::LDAP::Entry->new;
            $entry3->dn("cn=invalid result,$base");
            $entry3->add(
                cn => 'invalid result',
                description =>
                    'This entry will result in ASN1 error when queried'
            );
            push @entries, $entry3;
        }
        else {

            # base
            my $entry = Net::LDAP::Entry->new;
            $entry->dn($base);
            $entry->add(
                dn => $base,
                sn => 'value1',
                cn => [qw(value1 value2)]
            );
            push @entries, $entry;
        }
        return RESULT_OK, @entries;
    }

    sub add {
        my ( $self, $reqData, $reqMsg ) = @_;

        #warn 'ADD: ' . Data::Dump::dump \@_;

        my $entry = Net::LDAP::Entry->new;
        my $key   = $reqData->{objectName};
        $entry->dn($key);
        for my $attr ( @{ $reqData->{attributes} } ) {
            $entry->add( $attr->{type} => \@{ $attr->{vals} } );
        }

        $Data{$key} = $entry;

        if ( exists $self->{_flags}->{active_directory} ) {
            $self->_add_AD( $reqData, $reqMsg, $key, $entry, \%Data );
        }

        return RESULT_OK;
    }

    sub modify {
        my ( $self, $reqData, $reqMsg ) = @_;

        #warn 'MODIFY: ' . Data::Dump::dump \@_;

        my $key = $reqData->{object};
        if ( !exists $Data{$key} ) {
            croak "can't modify a non-existent entry: $key";
        }

        my @mods = @{ $reqData->{modification} };
        for my $mod (@mods) {
            my $attr  = $mod->{modification}->{type};
            my $vals  = $mod->{modification}->{vals};
            my $entry = $Data{$key};
            $entry->replace( $attr => $vals );
        }

        if ( $self->{_flags}->{active_directory} ) {
            $self->_modify_AD( $reqData, $reqMsg, \%Data );
        }

        return RESULT_OK;

    }

    sub delete {
        my ( $self, $reqData, $reqMsg ) = @_;

        #warn 'DELETE: ' . Data::Dump::dump \@_;

        my $key = $reqData;
        if ( !exists $Data{$key} ) {
            croak "can't delete a non-existent entry: $key";
        }
        delete $Data{$key};

        return RESULT_OK;

    }

    sub modifyDN {
        my ( $self, $reqData, $reqMsg ) = @_;

        #warn "modifyDN: " . Data::Dump::dump \@_;

        my $oldkey = $reqData->{entry};
        my $newkey = join( ',', $reqData->{newrdn}, $reqData->{newSuperior} );
        if ( !exists $Data{$oldkey} ) {
            croak "can't modifyDN for non-existent entry: $oldkey";
        }
        my $entry    = $Data{$oldkey};
        my $newentry = $entry->clone;
        $newentry->dn($newkey);
        $Data{$newkey} = $newentry;

        #warn "created new entry: $newkey";
        if ( $reqData->{deleteoldrdn} ) {
            delete $Data{$oldkey};

            #warn "deleted old entry: $oldkey";
        }

        return RESULT_OK;
    }

    sub compare {
        my ( $self, $reqData, $reqMsg ) = @_;

        #warn "compare: " . Data::Dump::dump \@_;

        return RESULT_OK;
    }

    sub abandon {
        my ( $self, $reqData, $reqMsg ) = @_;

        #warn "abandon: " . Data::Dump::dump \@_;

        return RESULT_OK;
    }

    my $token_counter = 100;
    my $sid_str       = 'S-1-2-3-4-5-6-1234';

    sub _get_server_sid_string { return $sid_str }

    sub _string2sid {
        my ($string) = @_;

        my ( undef, $revision_level, $authority, @sub_authorities )
            = split /-/, $string;
        my $sub_authority_count = scalar @sub_authorities;

        my $sid = pack 'C Vxx C V*', $revision_level, $authority,
            $sub_authority_count, @sub_authorities;

        if ( $ENV{LDAP_DEBUG} ) {
            carp "sid    = " . join( '\\', unpack '(H2)*', $sid );
            carp "string = $string";
        }

        return $sid;
    }

    sub _sid2string {
        my ($sid) = @_;

        my ($revision_level,      $authority,
            $sub_authority_count, @sub_authorities
        ) = unpack 'C Vxx C V*', $sid;

        die if $sub_authority_count != scalar @sub_authorities;

        my $string = join '-', 'S', $revision_level, $authority,
            @sub_authorities;

        if ( $ENV{LDAP_DEBUG} ) {
            carp "sid    = " . join( '\\', unpack '(H2)*', $sid );
            carp "string = $string";
        }
        return $string;
    }

    sub _add_AD {
        my ( $server, $reqData, $reqMsg, $key, $entry, $data ) = @_;

        for my $attr ( @{ $reqData->{attributes} } ) {
            if ( $attr->{type} eq 'objectClass' ) {
                if ( grep { $_ eq 'group' } @{ $attr->{vals} } ) {

                    # groups
                    $token_counter++;
                    ( my $group_sid_str = _get_server_sid_string() )
                        =~ s/-1234$/-$token_counter/;
                    if ( $ENV{LDAP_DEBUG} ) {
                        carp "group_sid_str = $group_sid_str";
                    }
                    $entry->add( 'primaryGroupToken' => $token_counter );
                    $entry->add( 'objectSID'         => "$group_sid_str" );
                    $entry->add( 'distinguishedName' => $key );

                }
                else {

                    # users
                    my $gid = $entry->get_value('primaryGroupID');
                    $gid = '1234' unless ( defined $gid );
                    ( my $user_sid_str = _get_server_sid_string() )
                        =~ s/-1234$/-$gid/;

                    my $user_sid = _string2sid($user_sid_str);

                    if ( $ENV{LDAP_DEBUG} ) {
                        carp "user_sid        = "
                            . join( '\\', unpack '(H2)*', $user_sid );
                        carp "user_sid_string = $user_sid_str";
                    }

                    $entry->add( 'objectSID'         => $user_sid );
                    $entry->add( 'distinguishedName' => $key );

                }
            }

        }

        _update_groups($data);

        #dump $reqData;
        #dump $data;

    }

    # AD stores group assignments in 'member' attribute
    # of each group. 'memberOf' is linked internally to that
    # attribute. We set 'memberOf' here if mimicing AD.
    sub _update_groups {
        my $data = shift;

        # all groups
        for my $key ( keys %$data ) {
            my $entry = $data->{$key};

            #warn "groups: update groups for $key";
            if ( !$entry->get_value('sAMAccountName') ) {

                #dump $entry;

                # group entry.
                # are the users listed in member
                # still assigned in their memberOf?
                my %users = map { $_ => 1 } $entry->get_value('member');
                for my $dn ( keys %users ) {

                    #warn "User $dn is a member in $key";
                    my $user = $data->{$dn};
                    my %groups = map { $_ => 1 } $user->get_value('memberOf');

                    # if $user does not list $key (group) as a memberOf,
                    # then add it.
                    if ( !exists $groups{$key} && exists $users{$dn} ) {
                        $groups{$key}++;
                        $user->replace( memberOf => [ keys %groups ] );
                    }
                }

            }

        }

        # all users

        for my $key ( keys %$data ) {
            my $entry = $data->{$key};

            #warn "users: update groups for $key";
            if ( $entry->get_value('sAMAccountName') ) {

                #dump $entry;

                # user entry
                # get its groups and add this user to each of them.
                my %groups = map { $_ => 1 } $entry->get_value('memberOf');
                for my $dn ( keys %groups ) {
                    my $group = $data->{$dn};
                    my %users
                        = map { $_ => 1 } ( $group->get_value('member') );

                    # if group no longer lists this user as a member,
                    # remove group from memberOf
                    if ( !exists $users{$key} ) {
                        delete $groups{$dn};
                        $entry->replace( memberOf => [ keys %groups ] );
                    }
                }

            }
        }

    }

    sub _modify_AD {
        my ( $server, $reqData, $reqMsg, $data ) = @_;

        #dump $data;
        _update_groups($data);

        #Data::Dump::dump $data;

    }

    # override the default behaviour to support controls
    sub handle {
        my $self = shift;
        my $socket;

        #warn "$Net::LDAP::Server::VERSION";
        if ( $Net::LDAP::Server::VERSION ge '0.43' ) {
            $socket = $self->{in};
        }
        else {
            $socket = $self->{socket};
        }

        asn_read( $socket, my $pdu );

        #print '-' x 80,"\n";
        #print "Received:\n";
        #Convert::ASN1::asn_dump(\*STDOUT,$pdu);
        my $request = $LDAPRequest->decode($pdu);
        my $mid     = $request->{'messageID'}
            or return 1;

        #print "messageID: $mid\n";
        #use Data::Dumper; print Dumper($request);

        my $reqType;
        foreach my $type (@Net::LDAP::Server::reqTypes) {
            if ( defined $request->{$type} ) {
                $reqType = $type;
                last;
            }
        }
        my $respType = $Net::LDAP::Server::respTypes{$reqType}
            or
            return 1;   # if no response type is present hangup the connection

        my $reqData = $request->{$reqType};

        # here we can do something with the request of type $reqType
        my $method = $Net::LDAP::Server::functions{$reqType};
        my ( $result, $controls );
        if ( $self->can($method) ) {
            if ( $method eq 'search' ) {
                my @entries;
                eval {
                    ( $result, @entries )
                        = $self->search( $reqData, $request );
                    if ( ref( $entries[0] ) eq 'ARRAY' ) {
                        $controls = pop(@entries);
                        @entries  = @{ shift(@entries) };

                        #warn "got controls";
                    }
                };

                # rethrow
                if ($@) {
                    croak $@;
                }

                foreach my $entry (@entries) {
                    my $data;

                    # default is to return a searchResEntry
                    my $sResType = 'searchResEntry';
                    if ( ref $entry eq 'Net::LDAP::Entry' ) {
                        $data = $entry->{'asn'};
                    }
                    elsif ( ref $entry eq 'Net::LDAP::Reference' ) {
                        $data     = $entry->{'asn'};
                        $sResType = 'searchResRef';
                    }
                    else {
                        $data = $entry;
                    }

                    my $response;

                    #  is the full message specified?
                    if ( defined $data->{'protocolOp'} ) {
                        $response = $data;
                        $response->{'messageID'} = $mid;
                    }
                    else {
                        $response = {
                            'messageID'  => $mid,
                            'protocolOp' => { $sResType => $data },
                        };
                    }
                    my $pdu = $LDAPResponse->encode($response);
                    if ($pdu) {
                        print {$socket} $pdu;
                    }
                    else {
                        $result = undef;
                        last;
                    }
                }
            }
            else {
                eval { $result = $self->$method( $reqData, $request ) };
            }
            $result = Net::LDAP::Server::_operations_error() unless $result;
        }
        else {
            $result = {
                'matchedDN'    => '',
                'errorMessage' => sprintf(
                    "%s operation is not supported by %s",
                    $method, ref $self
                ),
                'resultCode' => LDAP_UNWILLING_TO_PERFORM
            };
        }

        # and now send the result to the client
        print {$socket} _encode_result( $mid, $respType, $result, $controls );

        return 0;
    }

    sub _encode_result {
        my ( $mid, $respType, $result, $controls ) = @_;

        my $response = {
            'messageID'  => $mid,
            'protocolOp' => { $respType => $result },
        };
        if ( defined $controls ) {
            $response->{'controls'} = $controls;
        }

        #warn "response: " . Data::Dump::dump($response) . "\n";

        my $pdu = $LDAPResponse->encode($response);

        # if response encoding failed return the error
        if ( !$pdu ) {
            $response->{'protocolOp'}->{$respType}
                = Net::LDAP::Server::_operations_error();
            delete $response->{'controls'};    # just in case
            $pdu = $LDAPResponse->encode($response);
        }

        return $pdu;
    }

}    # end MyLDAPServer

=head2 new( I<port>, I<key_value_args> )

Create a new server. Basically this just fork()s a child process
listing on I<port> and handling requests using Net::LDAP::Server.

I<port> defaults to 10636.

I<key_value_args> may be:

=over

=item data

I<data> is optional data to return from the Net::LDAP search() function.
Typically it would be an array ref of Net::LDAP::Entry objects.

=item auto_schema

A true value means the add(), modify() and delete() methods will
store internal in-memory data based on DN values, so that search()
will mimic working on a real LDAP schema.

=item active_directory

Work in Active Directory mode. This means that entries are automatically
assigned a objectSID, and some effort is made to mimic the member/memberOf
linking between AD Users and Groups.

=back

new() will croak() if there was a problem fork()ing a new server.

Returns a Net::LDAP::Server::Test object, which is just a
blessed reference to the PID of the forked server.

=cut

sub new {
    my $class = shift;
    my $port  = shift || 10636;
    my %arg   = @_;

    if ( $arg{data} and $arg{auto_schema} ) {
        croak
            "cannot handle both 'data' and 'auto_schema' features. Pick one.";
    }

    pipe( my $r_fh, my $w_fh );

    my $pid = fork();

    if ( !defined $pid ) {
        croak "can't fork a LDAP test server: $!";
    }
    elsif ( $pid == 0 ) {

        warn "Creating new LDAP server on port $port ... \n";

        # the child (server)
        my $sock = IO::Socket::INET->new(
            Listen    => 5,
            Proto     => 'tcp',
            Reuse     => 1,
            LocalPort => $port
        ) or die "Unable to listen on port $port: $!";

        # tickle the pipe to show we've opened ok
        syswrite $w_fh, "Ready\n";
        undef $w_fh;

        my $sel = IO::Select->new($sock);
        my %Handlers;
        while ( my @ready = $sel->can_read ) {
            foreach my $fh (@ready) {
                if ( $fh == $sock ) {

                    # let's create a new socket
                    my $psock = $sock->accept;
                    $sel->add($psock);
                    $Handlers{*$psock} = MyLDAPServer->new( $psock, %arg );

                    #warn "new socket created";
                }
                else {
                    my $result = $Handlers{*$fh}->handle;
                    if ($result) {

                        # we have finished with the socket
                        $sel->remove($fh);
                        $fh->close;
                        delete $Handlers{*$fh};

                        # if there are no open connections,
                        # exit the child process.
                        if ( !keys %Handlers ) {
                            warn " ... shutting down server\n";
                            exit(0);
                        }
                    }
                }
            }
        }

        # if we get here, we had some kinda problem.
        croak "reached the end of while() loop prematurely";

    }
    else {

        return unless <$r_fh> =~ /Ready/;    # newline varies
        close($r_fh);
        return bless( \$pid, $class );
    }

}

=head2 stop

Calls waitpid() on the server's associated child process.
You may find it helpful to call this method explicitly,
especially if you are creating multiple
servers in the same test. Otherwise, this method is typically not
needed and may even cause your tests to hang indefinitely if
they die prematurely. YMMV.

=cut

sub stop {
    my $server = shift;
    my $pid    = $$server;
    return waitpid( $pid, 0 );
}

=head1 AUTHOR

Peter Karman, C<< <karman at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-net-ldap-server-test at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-LDAP-Server-Test>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Net::LDAP::Server::Test

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Net-LDAP-Server-Test>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Net-LDAP-Server-Test>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Net-LDAP-Server-Test>

=item * Search CPAN

L<http://search.cpan.org/dist/Net-LDAP-Server-Test>

=back

=head1 ACKNOWLEDGEMENTS

The Minnesota Supercomputing Institute C<< http://www.msi.umn.edu/ >>
sponsored the development of this software.

=head1 COPYRIGHT & LICENSE

Copyright 2007 by the Regents of the University of Minnesota.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

Net::LDAP::Server

=cut

1;
