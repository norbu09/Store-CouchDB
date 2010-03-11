package Store::CouchDB;

use Moose;
use JSON;
use LWP::UserAgent;
use URI;
use Data::Dumper;
use Encoding::FixLatin qw(fix_latin);

our $VERSION = '1.0';

has 'debug' => (
    is        => 'rw',
    required  => 1,
    default   => sub { },
    predicate => 'is_debug',
);

has 'host' => (
    is       => 'rw',
    required => 1,
    default  => sub { 'localhost' }
);

has 'port' => (
    is       => 'rw',
    required => 1,
    default  => sub { '5984' }
);

has 'db' => (
    is       => 'rw',
    required => 1,
    default  => sub { '' }
);

has 'method' => (
    is       => 'rw',
    required => 1,
    default  => sub { 'GET' }
);

has 'err' => (
    is        => 'rw',
    predicate => 'has_err',
);

sub get_doc {
    my ( $self, $data ) = @_;
    confess "Document ID not defiend" unless $data->{id};
    if ( $data->{dbname} ) {
        $self->db( $data->{dbname} );
    }
    my $path = $self->db . '/' . $data->{id};
    return $self->_call($path);
}

sub put_doc {
    my ( $self, $data ) = @_;
    confess "Document not defiend" unless $data->{doc};
    if ( $data->{dbname} ) {
        $self->db( $data->{dbname} );
    }
    my $path;
    my $method = $self->method();
    if ( $data->{doc}->{_id} ) {
        $self->method('PUT');
        $path = $self->db . '/' . $data->{doc}->{_id};
        delete $data->{doc}->{_id};
    }
    else {
        $self->method('POST');
        $path = $self->db;
    }
    my $res = $self->_call( $path, $data->{doc} );
    $self->method($method);
    return $res->{id} || undef;
}

sub del_doc {
    my ( $self, $data ) = @_;
    my $id  = $data->{id}  || $data->{_id};
    my $rev = $data->{rev} || $data->{_rev};
    confess "Document ID not defiend"       unless $id;
    if (!$rev) {
        my $doc = $self->get_doc({id => $id});
        $rev = $doc->{_rev};
    }
    if ( $data->{dbname} ) {
        $self->db( $data->{dbname} );
    }
    my $path;
    confess "Database not defiend" unless $self->db;
    $self->method('DELETE');
    $path = $self->db . '/' . $id . '?rev=' . $rev;
    my $res = $self->_call($path);
    return $res->{rev} || undef;

}

sub update_doc {
    my ( $self, $data ) = @_;
    confess "Document not defiend" unless $data->{doc};
    if ( $data->{name} ) {
        $data->{doc}->{_id} = $data->{name};
    }
    if ( $data->{dbname} ) {
        $self->db( $data->{dbname} );
    }
    return $self->put_doc($data);
}

sub copy_doc {
    my ( $self, $data ) = @_;
    confess "Document ID not defiend" unless $data->{id};

    # as long as CouchDB does not support automatic document name creation
    # for the copy command we copy the ugly way ...
    if ( $data->{dbname} ) {
        $self->db( $data->{dbname} );
    }
    my $doc = $self->get_doc($data);
    delete $doc->{_id};
    delete $doc->{_rev};
    return $self->put_doc( { doc => $doc } );
}

sub get_view {
    my ( $self, $data ) = @_;
    confess "View not defiend" unless $data->{view};
    if ( $data->{dbname} ) {
        $self->db( $data->{dbname} );
    }
    my $path = $self->_make_view_path($data);
    my $res  = $self->_call($path);

    return unless $res->{rows}->[0];
    my $c = 0;
    my $result;
    foreach my $doc ( @{ $res->{rows} } ) {
        next unless $doc->{value};

        # TODO debug why this crashes from time to time
        #$doc->{value}->{id} = $doc->{id};
        $result->{ $doc->{key} || $c } = $doc->{value};
        $c++;
    }
    return $result;
}

sub get_post_view {
    my ( $self, $data ) = @_;
    confess "View not defiend"                            unless $data->{view};
    confess "No options defiend - use 'get_view' instead" unless $data->{opts};
    if ( $data->{dbname} ) {
        $self->db( $data->{dbname} );
    }
    my $opts;
    if ( $data->{opts} ) {
        $opts = delete $data->{opts};
    }
    my $path = $self->_make_view_path($data);
    my $method = $self->method();
    $self->method('POST');
    my $res = $self->_call( $path, $opts );
    $self->method($method);
    my $result;
    foreach my $doc ( @{ $res->{rows} } ) {
        next unless $doc->{value};
        $doc->{value}->{id} = $doc->{id};
        $result->{ $doc->{key} } = $doc->{value};
    }
    return $result;
}

sub get_array_view {
    my ( $self, $data ) = @_;
    confess "View not defiend" unless $data->{view};
    if ( $data->{dbname} ) {
        $self->db( $data->{dbname} );
    }
    my $path = $self->_make_view_path($data);
    my $res  = $self->_call($path);
    my $result;
    foreach my $doc ( @{ $res->{rows} } ) {
        next unless $doc->{value};
        $doc->{value}->{id} = $doc->{id};
        push( @{$result}, $doc->{value} );
    }
    return $result;
}

sub config {
    my ( $self, $data ) = @_;

    foreach my $key ( keys %{ $data } )
    {
        $self->$key($data->{$key}) or confess "$key not defined as property!";
    }
    return $self;
}

sub _make_view_path {
    my ( $self, $data ) = @_;
    $data->{view} =~ s/^\///;
    my @view = split( /\//, $data->{view}, 2 );
    my $path = $self->db . '/_design/' . $view[0] . '/_view/' . $view[1];
    if ( $data->{opts} ) {
        my @opts;
        foreach my $opt ( keys %{ $data->{opts} } ) {
            push( @opts, $opt . '=' . $data->{opts}->{$opt} );
        }
        my $_opt = join( '&', @opts );
        $path .= '?' . $_opt;
    }
    return $path;
}

sub _call {
    my ( $self, $path, $content ) = @_;
    my $uri = 'http://' . $self->host . ':' . $self->port . '/' . $path;
    print STDERR "URI: $uri\n" if $self->is_debug;

    my $req = HTTP::Request->new();
    $req->method( $self->method );
    $req->uri($uri);
    $req->content( fix_latin( to_json($content, {allow_blessed => 1, convert_blessed => 1}), bytes_only => 1 ) )
      if ($content);

    my $ua  = LWP::UserAgent->new();
    my $res = $ua->request($req);
    print STDERR "Result: " . $res->decoded_content . "\n" if $self->is_debug;
    if ( $res->is_success ) {
        return from_json( $res->decoded_content, { allow_nonref => 1 } );
    }
    else {
        $self->err( $res->status_line );
    }
    return;
}

=head1 NAME

Store::CouchDB - a simple CouchDB driver

=head1 VERSION

$VERSION = "0.4"

=cut

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Store::CouchDB;

    my $db = Store::CouchDB->new();
    $db->config({host => 'localhost', db => 'your_db'});
    my $couch = {
        view   => 'design_doc/view',
        opts   => { key => '"' . $key . '"' },
    };
    my $status = $db->get_array_view($couch);


=head1 EXPORT

A list of functions that can be exported.  You can delete this section
if you don't export anything, such as for a purely object-oriented module.

=head1 FUNCTIONS

=head2 get_doc

=head2 put_doc

=head2 del_doc

=head2 update_doc

=head2 copy_doc

=head2 get_view

=head2 get_post_view

=head2 get_array_view

=head2 config

=cut

=head1 AUTHOR

Lenz Gschwendtner, C<< <norbu09 at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-store-couchdb at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Store-CouchDB>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Store::CouchDB


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Store-CouchDB>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Store-CouchDB>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Store-CouchDB>

=item * Search CPAN

L<http://search.cpan.org/dist/Store-CouchDB/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2009 Lenz Gschwendtner.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1;    # End of Store::CouchDB
