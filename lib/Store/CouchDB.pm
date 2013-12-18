package Store::CouchDB;

use Any::Moose;

# ABSTRACT: Store::CouchDB - a simple CouchDB driver

# VERSION

use JSON;
use LWP::UserAgent;
use URI::Escape;
use Carp;

=head1 SYNOPSIS

Store::CouchDB is a very thin wrapper around CouchDB. It is essentially
a set of calls I use in production and is by no means a complete
library, it is just complete enough for the things I need to do. This is
a grown set of functions that evolved over the last years of using
CouchDB in various projects and was written originally to be compatible
with DB::CouchDB. This has long passed and can only be noticed at some
places.

One of the things I banged my head against for some time is non UTF8
stuff that somehow enters the system and then breaks CouchDB. I use the
brilliant Encoding::FixLatin module to fix this on the fly.

    use Store::CouchDB;
    
    my $sc = Store::CouchDB->new(host => 'localhost', db => 'your_db');
    # OR
    my $sc = Store::CouchDB->new();
    $sc->config({host => 'localhost', db => 'your_db'});
    my $array_ref = $db->get_array_view({
        view   => 'design_doc/view',
        opts   => { key => $key },
    });

=head1 ATTRIBUTES

=head2 debug

Sets the class in debug mode

Default: false

=cut

has 'debug' => (
    is      => 'rw',
    isa     => 'Bool',
    default => sub { 0 },
    lazy    => 1,
);

=head2 host

Default: localhost

=cut

has 'host' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
    default  => sub { 'localhost' },
);

=head2 port

Default: 5984

=cut

has 'port' => (
    is       => 'rw',
    isa      => 'Int',
    required => 1,
    default  => sub { 5984 },
);

=head2 ssl

Connect to host using SSL/TLS.

Default: false

=cut

has 'ssl' => (
    is      => 'rw',
    isa     => 'Bool',
    default => sub { 0 },
    lazy    => 1,
);

=head2 db

The databae name to use. This has to be set for all oprations!

=cut

has 'db' => (
    is        => 'rw',
    isa       => 'Str',
    required  => 1,
    lazy      => 1,
    default   => sub { },
    predicate => 'has_db',
);

=head2 user

The DB user to authenticate as. optional

=cut

has 'user' => (
    is  => 'rw',
    isa => 'Str',
);

=head2 pass

The password for the user to authenticate with. required if user is given.

=cut

has 'pass' => (
    is  => 'rw',
    isa => 'Str',
);

=head2 method

This is internal and sets the request method to be used (GET|POST)

Default: GET

=cut

has 'method' => (
    is       => 'rw',
    required => 1,
    default  => sub { 'GET' },
);

=head2 error

This is set if an error has occured and can be called to get the last
error with the 'has_error' predicate.

    $sc->has_error

Error string if there was an error

=cut

has 'error' => (
    is        => 'rw',
    predicate => 'has_error',
    clearer   => 'clear_error',
);

=head2 purge_limit

How many documents shall we try to purge.

Default: 5000

=cut

has 'purge_limit' => (
    is      => 'rw',
    default => sub { 5000 },
);

=head2 timeout

Timeout in seconds for each HTTP request. Passed onto LWP::UserAgent

Default: 30

=cut

has 'timeout' => (
    is      => 'rw',
    isa     => 'Int',
    default => sub { 30 },
);

=head2 json

=cut

has 'json' => (
    is      => 'rw',
    isa     => 'JSON',
    default => sub {
        JSON->new->utf8->allow_nonref->allow_blessed->convert_blessed;
    },
);

=head1 METHODS

=head2 new

The Store::CouchDB class takes a any of the attributes described above as parameters.

=head2 get_doc

The get_doc call returns a document by its ID. If no document ID is given it
returns undef

    $sc->get_doc({ id => 'DOCUMENT_ID', dbname => 'DATABASE' });

where the dbname key is optional. Alternatively this works too:

    $sc->get_doc('DOCUMENT_ID');

=cut

sub get_doc {
    my ($self, $data) = @_;

    unless (ref $data eq 'HASH') {
        $data = { id => $data };
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    unless ($data->{id}) {
        carp 'Document ID not defined';
        return;
    }

    my $path = $self->db . '/' . $data->{id};

    return $self->_call($path);
}

=head2 head_doc

If all you need is the revision a HEAD call is enough.

=cut

sub head_doc {
    my ($self, $data) = @_;

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    unless ($data->{id}) {
        carp 'Document ID not defined';
        return;
    }

    $self->method('HEAD');
    my $path = $self->db . '/' . $data->{id};
    my $rev  = $self->_call($path);
    $rev =~ s/"//g;

    return $rev;
}

=head2 get_design_docs

The get_design_docs call returns all design document names in an array
reference.

    $sc->get_design_docs({ dbname => 'DATABASE' });

Again the "dbname" key is optional.

=cut

sub get_design_docs {
    my ($self, $data) = @_;

    if ($data && $data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    my $path = $self->db
        . '/_all_docs?descending=true&startkey="_design0"&endkey="_design"';
    $self->method('GET');
    my $res = $self->_call($path);

    return unless $res->{rows}->[0];

    my @design;
    foreach my $_design (@{ $res->{rows} }) {
        my ($_d, $name) = split(/\//, $_design->{key}, 2);
        push(@design, $name);
    }

    return \@design;
}

=head2 put_doc

The put_doc call writes a document to the database and either updates a
existing document if the _id field is present or writes a new one.
Updates can also be done with the update_doc call but that is really
just a wrapper for put_doc.

    $sc->put_doc({ doc => {DOCUMENT}, dbname => 'DATABASE' });

=cut

sub put_doc {
    my ($self, $data) = @_;

    unless ($data->{doc} and ref $data->{doc} eq 'HASH') {
        carp "Document not defined";
        return;
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    my $path;
    my $method = $self->method;

    if ($data->{doc}->{_id}) {
        $self->method('PUT');
        $path = $self->db . '/' . $data->{doc}->{_id};
        delete $data->{doc}->{_id};
    }
    else {
        $self->method('POST');
        $path = $self->db;
    }

    my $res = $self->_call($path, $data->{doc});
    $self->method($method);

    return ($res->{id} || undef, $res->{rev} || undef) if wantarray;
    return $res->{id} || undef;
}

=head2 del_doc

The del_doc call marks a document as deleted. CouchDB needs a revision
to delete a document which is good for security but is not practical for
me in some situations. If no revision is supplied del_doc will get the
document, find the latest revision and delete the document. Returns the
REVISION in SCALAR context, DOCUMENT_ID and REVISION in array context.

    $sc->del_doc({ id => 'DOCUMENT_ID', rev => 'REVISION', dbname => 'DATABASE' });

=cut

sub del_doc {
    my ($self, $data) = @_;

    my $id  = $data->{id}  || $data->{_id};
    my $rev = $data->{rev} || $data->{_rev};

    unless ($id) {
        carp 'Document ID not defined';
        return;
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    if (!$rev) {
        $rev = $self->head_doc({ id => $id });
    }

    my $path;
    $self->method('DELETE');
    $path = $self->db . '/' . $id . '?rev=' . $rev;
    my $res = $self->_call($path);
    $self->method('GET');

    return ($res->{id} || undef, $res->{rev} || undef) if wantarray;
    return $res->{rev} || undef;
}

=head2 update_doc

The update_doc function is really just a wrapper for the put_doc call
and mainly there for compatibility. the naming is different and it is
discouraged to use it and it may disappear in a later version.

    $sc->update_doc({ doc => DOCUMENT, name => 'DOCUMENT_ID', dbname => 'DATABASE' });

=cut

sub update_doc {
    my ($self, $data) = @_;

    unless ($data->{doc}) {
        carp "Document not defined";
        return;
    }

    if ($data->{name}) {
        $data->{doc}->{_id} = $data->{name};
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    return $self->put_doc($data);
}

=head2 copy_doc

The copy_doc is _not_ the same as the CouchDB equivalent. In CouchDB the
copy command wants to have a name/id for the new document which is
mandatory and can not be ommitted. I find that inconvenient and made
this small wrapper. All it does is getting the doc to copy, removes the
_id and _rev fields and saves it back as a new document.

    $sc->copy_doc({ id => 'DOCUMENT_ID', dbname => 'DATABASE' });

=cut

sub copy_doc {
    my ($self, $data) = @_;

    unless ($data->{id}) {
        carp "Document ID not defined";
        return;
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    # as long as CouchDB does not support automatic document name creation
    # for the copy command we copy the ugly way ...
    my $doc = $self->get_doc($data);
    delete $doc->{_id};
    delete $doc->{_rev};

    return $self->put_doc({ doc => $doc });
}

=head2 get_view

There are several ways to represent the result of a view and various
ways to query for a view. All the views support parameters but there are
different functions for GET/POST view handling and representing the
reults.
The get_view uses GET to call the view and returns a hash with the _id
as the key and the document as a value in the hash structure. This is
handy for getting a hash structure for several documents in the DB.

    $sc->get_view({
        view => 'design_doc/view',
        opts => { key => $key },
    });

=cut

sub get_view {
    my ($self, $data) = @_;

    unless ($data->{view}) {
        carp "View not defined";
        return;
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    my $path = $self->_make_view_path($data);
    my $res  = $self->_call($path);

    return unless $res->{rows}->[0];

    my $c      = 0;
    my $result = {};
    foreach my $doc (@{ $res->{rows} }) {
        if ($doc->{doc}) {
            $result->{ $doc->{key} || $c } = $doc->{doc};
        }
        else {
            next unless exists $doc->{value};
            if (ref $doc->{key} eq 'ARRAY') {
                _hash($result, $doc->{value}, @{ $doc->{key} });
            }
            else {
                # TODO debug why this crashes from time to time
                #$doc->{value}->{id} = $doc->{id};
                $result->{ $doc->{key} || $c } = $doc->{value};
            }
        }
        $c++;
    }

    return $result;
}

=head2 get_post_view

The get_post_view uses POST to call the view and returns a hash with the _id
as the key and the document as a value in the hash structure. This is
handy for getting a hash structure for several documents in the DB.

    $sc->get_post_view({
        view => 'DESIGN_DOC/VIEW',
        opts => [ $key1, $key2, $key3, ... ],
    });

=cut

sub get_post_view {
    my ($self, $data) = @_;

    unless ($data->{view}) {
        carp 'View not defined';
        return;
    }
    unless ($data->{opts}) {
        carp 'No options defined - use "get_view" instead';
        return;
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    my $opts;
    if ($data->{opts}) {
        $opts = delete $data->{opts};
    }
    my $path   = $self->_make_view_path($data);
    my $method = $self->method();

    $self->method('POST');
    my $res = $self->_call($path, $opts);
    $self->method($method);

    my $result;
    foreach my $doc (@{ $res->{rows} }) {
        next unless exists $doc->{value};
        $doc->{value}->{id} = $doc->{id};
        $result->{ $doc->{key} } = $doc->{value};
    }

    return $result;
}

=head2 get_view_array

Same as get_array_view only returns a real array ref. Use either one
depending on your use case and convenience.

=cut

sub get_view_array {
    my ($self, $data) = @_;

    unless ($data->{view}) {
        carp 'View not defined';
        return;
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    my $path = $self->_make_view_path($data);
    my $res  = $self->_call($path);

    my @result;
    foreach my $doc (@{ $res->{rows} }) {
        if ($doc->{doc}) {
            push(@result, $doc->{doc});
        }
        else {
            next unless exists $doc->{value};
            if (ref($doc->{value}) eq 'HASH') {
                $doc->{value}->{id} = $doc->{id};
                push(@result, $doc->{value});
            }
            else {
                push(@result, $doc);
            }
        }
    }

    return \@result;
}

=head2 get_array_view

The get_array_view uses GET to call the view and returns an array
reference of matched documents. This view functions is the one I use
most and has the best support for corner cases.

    $sc->get_array_view({
        view => 'DESIGN_DOC/VIEW',
        opts => { key => $key },
    });

A normal response hash would be the "value" part of the document with
the _id moved in as "id". If the response is not a HASH (the request was
resulting in key/value pairs) the entire doc is returned resulting in a
hash of key/value/id per document.

=cut

sub get_array_view {
    my ($self, $data) = @_;

    unless ($data->{view}) {
        carp "View not defined";
        return;
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    my $path = $self->_make_view_path($data);
    my $res  = $self->_call($path);

    my $result;
    foreach my $doc (@{ $res->{rows} }) {
        if ($doc->{doc}) {
            push(@{$result}, $doc->{doc});
        }
        else {
            next unless exists $doc->{value};
            if (ref($doc->{value}) eq 'HASH') {
                $doc->{value}->{id} = $doc->{id};
                push(@{$result}, $doc->{value});
            }
            else {
                push(@{$result}, $doc);
            }
        }
    }

    return $result;
}

=head2 purge

This function tries to find deleted documents via the _changes call and
then purges as many deleted documents as defined in $self->purge_limit
which currently defaults to 5000. This call is somewhat experimental in
the moment.

    $sc->purge({ dbname => 'DATABASE' });

=cut

sub purge {
    my ($self, $data) = @_;

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    my $path = $self->db . '/_changes?limit=' . $self->purge_limit . '&since=0';
    $self->method('GET');
    my $res = $self->_call($path);

    return unless $res->{results}->[0];

    my @del;
    $self->method('POST');
    my $resp;

    foreach my $_del (@{ $res->{results} }) {
        next unless ($_del->{deleted} and ($_del->{deleted} eq 'true'));
        my $opts = {

            #purge_seq => $_del->{seq},
            $_del->{id} => [ $_del->{changes}->[0]->{rev} ],
        };
        $resp->{ $_del->{seq} } = $self->_call($self->db . '/_purge', $opts);
    }

    return $resp;
}

=head2 compact

This compacts the DB file and optionally calls purge and cleans up the
view index as well.

    $sc->compact({ purge => 1, view_compact => 1 })

=cut

sub compact {
    my ($self, $data) = @_;

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    my $res;
    if ($data->{purge}) {
        $res->{purge} = $self->purge();
    }

    if ($data->{view_compact}) {
        $self->method('POST');
        $res->{view_compact} = $self->_call($self->db . '/_view_cleanup');
        my $design = $self->get_design_docs();
        $self->method('POST');
        foreach my $doc (@{$design}) {
            $res->{ $doc . '_compact' } =
                $self->_call($self->db . '/_compact/' . $doc);
        }
    }

    $self->method('POST');
    $res->{compact} = $self->_call($self->db . '/_compact');

    return $res;
}

=head2 put_file

To add an attachement to CouchDB use the put_file method. 'file' because
it is shorter than attachement and less prone to misspellings. The
put_file method works like the put_doc function and will add an
attachement to an existing doc if the '_id' parameter is given or addes
a new doc with the attachement if no '_id' parameter is given.
The only mandatory parameter is the 'file' parameter.

=cut

sub put_file {
    my ($self, $data) = @_;

    unless ($data->{file}) {
        carp 'File content not defined';
        return;
    }
    unless ($data->{filename}) {
        carp 'File name not defined';
        return;
    }

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    my $id  = $data->{id}  || $data->{doc}->{_id};
    my $rev = $data->{rev} || $data->{doc}->{_rev};
    my $method = $self->method();

    if (!$rev and $id) {
        $rev = $self->head_doc({ id => $id });
        print STDERR ">>$rev<<\n";
    }

    # create a new doc if required
    ($id, $rev) = $self->put_doc({ doc => {} }) unless $id;

    my $path = $self->db . '/' . $id . '/' . $data->{filename} . '?rev=' . $rev;

    $self->method('PUT');
    my $res = $self->_call($path, $data->{file}, $data->{content_type});
    $self->method($method);

    return ($res->{id} || undef, $res->{rev} || undef) if wantarray;
    return $res->{id} || undef;
}

=head2 get_file

Get a file attachement from a CouchDB document.

=cut

sub get_file {
    my ($self, $data) = @_;

    if ($data->{dbname}) {
        $self->db($data->{dbname});
    }

    $self->_check_db;

    unless ($data->{id}) {
        carp "Document ID not defined";
        return;
    }
    unless ($data->{filename}) {
        carp "File name not defined";
        return;
    }

    my $path = join('/', $self->db, $data->{id}, $data->{filename});

    return $self->_call($path);
}

=head2 config

This can be called with a hash of config values to configure the databse
object. I use it frequently with sections of config files.

    $sc->config({ host => 'HOST', port => 'PORT', db => 'DATABASE' });

=cut

sub config {
    my ($self, $data) = @_;

    foreach my $key (keys %{$data}) {
        $self->$key($data->{$key}) or confess "$key not defined as property!";
    }
    return $self;
}

=head2 create_db

Create a Database

    $sc->create_db('name');

=cut

sub create_db {
    my ($self, $db) = @_;

    if ($db) {
        $self->db($db);
    }

    my $method = $self->method();
    $self->method('PUT');
    my $res = $self->_call($self->db);
    $self->method($method);

    return $res;
}

sub _check_db {
    my ($self) = @_;

    unless ($self->has_db) {
        carp 'database missing! you must set $sc->db() before running queries';
        return;
    }

    return;
}

sub _make_view_path {
    my ($self, $data) = @_;

    my $view = $data->{view};
    $view =~ s/^\///;
    my @view = split(/\//, $view, 2);
    my $path = $self->db . '/_design/' . $view[0] . '/_view/' . $view[1];

    if (keys %{ $data->{opts} }) {
        $path .= '?';
        foreach my $key (keys %{ $data->{opts} }) {
            my $value = $data->{opts}->{$key};
            if ($key =~ m/key/) {
                $value = $self->json->encode($value);
            }
            $value = uri_escape($value);
            $path .= $key . '=' . $value . '&';
        }

        # remove last '&'
        chop($path);
    }

    return $path;
}

sub _call {
    my ($self, $path, $content, $ct) = @_;

    binmode(STDERR, ":utf8");

    # cleanup old error
    $self->clear_error if $self->has_error;

    my $uri = ($self->ssl) ? 'https://' : 'http://';
    $uri .= $self->user . ':' . $self->pass . '@'
        if ($self->user and $self->pass);
    $uri .= $self->host . ':' . $self->port . '/' . $path;
    print STDERR __PACKAGE__ . ": URI: $uri\n" if $self->debug;

    my $req = HTTP::Request->new();
    $req->method($self->method);
    $req->uri($uri);

    $req->content((
              $ct
            ? $content
            : $self->json->encode($content))) if ($content);

    my $ua = LWP::UserAgent->new(timeout => $self->timeout);

    $ua->default_header('Content-Type' => $ct || "application/json");
    my $res = $ua->request($req);

    if ($self->debug) {
        require Data::Dump;
        print STDERR __PACKAGE__
            . ": Result: "
            . Data::Dump::dump($res->decoded_content);
    }

    if ($self->method eq 'HEAD') {
        if ($self->debug) {
            print STDERR __PACKAGE__
                . ": Revision: "
                . $res->header('ETag') . "\n";
        }
        return $res->header('ETag') || undef;
    }
    elsif ($res->is_success) {
        my $result;
        eval { $result = $self->json->decode($res->content) };
        return $result unless $@;
        return {
            file         => $res->decoded_content,
            content_type => $res->content_type
        };
    }
    else {
        $self->error($res->status_line);
    }

    return;
}

sub _hash {
    my ($head, $val, @tail) = @_;
    if ($#tail == 0) {
        return $head->{ shift(@tail) } = $val;
    }
    else {
        return _hash($head->{ shift(@tail) } //= {}, $val, @tail);
    }
}

=head1 BUGS

Please report any bugs or feature requests on GitHub's issue tracker L<https://github.com/norbu09/Store-CouchDB/issues>.
Pull requests welcome.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Store::CouchDB


You can also look for information at:

=over 4

=item * GitHub repository

L<https://github.com/norbu09/Store-CouchDB>

=item * MetaCPAN

L<https://metacpan.org/module/Store::CouchDB>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Store::CouchDB>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Store::CouchDB>

=back


=head1 ACKNOWLEDGEMENTS

Thanks for DB::CouchDB which was very enspiring for writing this library

=cut

1;    # End of Store::CouchDB
