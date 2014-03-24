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
        view   => 'design_doc/view_name',
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

The databae name to use.

=cut

has 'db' => (
    is        => 'rw',
    isa       => 'Str',
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

    my $doc = $sc->get_doc({ id => 'doc_id', dbname => 'database' });

where the dbname key is optional. Alternatively this works too:

    my $doc = $sc->get_doc('doc_id');

=cut

sub get_doc {
    my ($self, $data) = @_;

    unless (ref $data eq 'HASH') {
        $data = { id => $data };
    }

    $self->_check_db($data);

    unless ($data->{id}) {
        carp 'Document ID not defined';
        return;
    }

    my $path = $self->db . '/' . $data->{id};

    $self->method('GET');

    return $self->_call($path);
}

=head2 head_doc

If all you need is the revision a HEAD call is enough.

    my $rev = $sc->head_doc('doc_id');

=cut

sub head_doc {
    my ($self, $data) = @_;

    unless (ref $data eq 'HASH') {
        $data = { id => $data };
    }

    $self->_check_db($data);

    unless ($data->{id}) {
        carp 'Document ID not defined';
        return;
    }

    my $path = $self->db . '/' . $data->{id};

    $self->method('HEAD');
    my $rev = $self->_call($path);

    $rev =~ s/"//g if $rev;

    return $rev;
}

=head2 get_design_docs

The get_design_docs call returns all design document names in an array
reference. You can add include_docs => 1 under the "opts" key to get the whole
design document.

    my @docs = @{ $sc->get_design_docs({ dbname => 'database' }) };

Again the "dbname" key is optional.

=cut

sub get_design_docs {
    my ($self, $data) = @_;

    $self->_check_db($data);

    my $path = $self->db
        . '/_all_docs?descending=true&startkey="_design0"&endkey="_design"';
    $path .= '&include_docs=true'
        if (ref $data eq 'HASH' && $data->{include_docs});

    $self->method('GET');
    my $res = $self->_call($path);

    return unless $res->{rows}->[0];
    return $res->{rows} if (ref $data eq 'HASH' && $data->{include_docs});

    my @design;
    foreach my $design (@{ $res->{rows} }) {
        my (undef, $name) = split(/\//, $design->{key}, 2);
        push(@design, $name);
    }

    return \@design;
}

=head2 put_doc

The put_doc call writes a document to the database and either updates a
existing document if the _id field is present or writes a new one.
Updates can also be done with the C<update_doc> call if you want to prevent
creation of a new document in case the document ID is missing in your input
hashref.

    my ($id, $rev) = $sc->put_doc({ doc => { .. }, dbname => 'database' });

=cut

sub put_doc {
    my ($self, $data) = @_;

    unless (exists $data->{doc} and ref $data->{doc} eq 'HASH') {
        carp "Document not defined";
        return;
    }

    $self->_check_db($data);

    my $path;
    if (exists $data->{doc}->{_id} and defined $data->{doc}->{_id}) {
        $self->method('PUT');
        $path = $self->db . '/' . $data->{doc}->{_id};
    }
    else {
        $self->method('POST');
        $path = $self->db;
    }

    my $res = $self->_call($path, $data->{doc});

    # update revision in original doc for convenience
    $data->{doc}->{_rev} = $res->{rev};

    return ($res->{id}, $res->{rev}) if wantarray;
    return $res->{id};
}

=head2 del_doc

The del_doc call marks a document as deleted. CouchDB needs a revision
to delete a document which is good for security but is not practical for
me in some situations. If no revision is supplied del_doc will get the
document, find the latest revision and delete the document. Returns the
revision in SCALAR context, document ID and revision in ARRAY context.

    my $rev = $sc->del_doc({ id => 'doc_id', rev => 'r-evision', dbname => 'database' });

=cut

sub del_doc {
    my ($self, $data) = @_;

    unless (ref $data eq 'HASH') {
        $data = { id => $data };
    }

    my $id  = $data->{id}  || $data->{_id};
    my $rev = $data->{rev} || $data->{_rev};

    unless ($id) {
        carp 'Document ID not defined';
        return;
    }

    $self->_check_db($data);

    # get doc revision if missing
    unless ($rev) {
        $rev = $self->head_doc($id);
    }

    # stop if doc doesn't exist
    unless ($rev) {
        carp "Document does not exist";
        return;
    }

    my $path;
    $path = $self->db . '/' . $id . '?rev=' . $rev;

    $self->method('DELETE');
    my $res = $self->_call($path);

    return ($res->{id}, $res->{rev}) if wantarray;
    return $res->{rev};
}

=head2 update_doc

B<WARNING: as of Version C<3.4> this method breaks old code!>

The use of C<update_doc()> was discouraged before this version and was merely a
wrapper for put_doc, which became unnecessary. Please make sure you update your
code if you were using this method before version C<3.4>.

C<update_doc> refuses to push a document if the document ID is missing or the
document does not exist. This will make sure that you can only update existing
documents and not accidentally create a new one.

            $id = $sc->update_doc({ doc => { _id => '', ... } });
    ($id, $rev) = $sc->update_doc({ doc => { .. }, name => 'doc_id', dbname => 'database' });

=cut

sub update_doc {
    my ($self, $data) = @_;

    unless (ref $data eq 'HASH'
        and exists $data->{doc}
        and ref $data->{doc} eq 'HASH')
    {
        carp "Document not defined";
        return;
    }

    if ($data->{name}) {
        $data->{doc}->{_id} = $data->{name};
    }

    unless (exists $data->{doc}->{_id} and defined $data->{doc}->{_id}) {
        carp "Document ID not defined";
        return;
    }

    $self->_check_db($data);

    my $rev = $self->head_doc($data->{doc}->{_id});
    unless ($rev) {
        carp "Document does not exist";
        return;
    }

    # store revision in original doc to be able to put_doc
    $data->{doc}->{_rev} = $rev;

    return $self->put_doc($data);
}

=head2 copy_doc

The copy_doc is _not_ the same as the CouchDB equivalent. In CouchDB the
copy command wants to have a name/id for the new document which is
mandatory and can not be ommitted. I find that inconvenient and made
this small wrapper. All it does is getting the doc to copy, removes the
_id and _rev fields and saves it back as a new document.

    my ($id, $rev) = $sc->copy_doc({ id => 'doc_id', dbname => 'database' });

=cut

sub copy_doc {
    my ($self, $data) = @_;

    unless (ref $data eq 'HASH') {
        $data = { id => $data };
    }

    unless ($data->{id}) {
        carp "Document ID not defined";
        return;
    }

    # as long as CouchDB does not support automatic document name creation
    # for the copy command we copy the ugly way ...
    my $doc = $self->get_doc($data);

    unless ($doc) {
        carp "Document does not exist";
        return;
    }

    delete $doc->{_id};
    delete $doc->{_rev};

    return $self->put_doc({ doc => $doc });
}

=head2 show_doc

call a show function on a document to transform it.

    my $content = $sc->show_doc({ show => 'design_doc/show_name' });

=cut

sub show_doc {
    my ($self, $data) = @_;

    $self->_check_db($data);

    unless ($data->{show}) {
        carp 'show not defined';
        return;
    }

    my $path = $self->_make_path($data);
    $path .= '/' . $data->{id} if defined $data->{id};

    $self->method('GET');

    return $self->_call($path);
}

=head2 get_view

There are several ways to represent the result of a view and various
ways to query for a view. All the views support parameters but there are
different functions for GET/POST view handling and representing the
reults.
The get_view uses GET to call the view and returns a hash with the _id
as the key and the document as a value in the hash structure. This is
handy for getting a hash structure for several documents in the DB.

    my $hashref = $sc->get_view({
        view => 'design_doc/view_name',
        opts => { key => $key },
    });

=cut

sub get_view {
    my ($self, $data) = @_;

    unless ($data->{view}) {
        carp "View not defined";
        return;
    }

    $self->_check_db($data);

    my $path = $self->_make_path($data);
    $self->method('GET');
    my $res = $self->_call($path);

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
                $self->_hash($result, $doc->{value}, @{ $doc->{key} });
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

    my $hashref = $sc->get_post_view({
        view => 'design_doc/view_name',
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

    $self->_check_db($data);

    my $opts;
    if ($data->{opts}) {
        $opts = delete $data->{opts};
    }
    my $path = $self->_make_path($data);

    $self->method('POST');
    my $res = $self->_call($path, $opts);

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

    $self->_check_db($data);

    my $path = $self->_make_path($data);
    $self->method('GET');
    my $res = $self->_call($path);

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

    my @docs = @{ $sc->get_array_view({
        view => 'design_doc/view_name',
        opts => { key => $key },
    }) };

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

    $self->_check_db($data);

    my $path = $self->_make_path($data);
    $self->method('GET');
    my $res = $self->_call($path);

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

=head2 list_view

use the _list function on a view to transform its output. if your view contains
a reduce function you have to add

    opts => { reduce => 'false' }

to your hash.

    my $content = $sc->list_view({
        list => 'list_name',
        view => 'design/view',
    #   opts => { reduce => 'false' },
    });

=cut

sub list_view {
    my ($self, $data) = @_;

    unless ($data->{list}) {
        carp "List not defined";
        return;
    }

    unless ($data->{view}) {
        carp "View not defined";
        return;
    }

    $self->_check_db($data);

    my $path = $self->_make_path($data);

    $self->method('GET');

    return $self->_call($path);
}

=head2 purge

This function tries to find deleted documents via the _changes call and
then purges as many deleted documents as defined in $self->purge_limit
which currently defaults to 5000. This call is somewhat experimental in
the moment.

    my $result = $sc->purge({ dbname => 'database' });

=cut

sub purge {
    my ($self, $data) = @_;

    $self->_check_db($data);

    my $path = $self->db . '/_changes?limit=' . $self->purge_limit . '&since=0';
    $self->method('GET');
    my $res = $self->_call($path);

    return unless $res->{results}->[0];

    my @del;
    my $resp;

    $self->method('POST');
    foreach my $_del (@{ $res->{results} }) {
        next
            unless (exists $_del->{deleted}
            and ($_del->{deleted} eq 'true' or $_del->{deleted} == 1));

        my $opts = { $_del->{id} => [ $_del->{changes}->[0]->{rev} ], };
        $resp->{ $_del->{seq} } = $self->_call($self->db . '/_purge', $opts);
    }

    return $resp;
}

=head2 compact

This compacts the DB file and optionally calls purge and cleans up the
view index as well.

    my $result = $sc->compact({ purge => 1, view_compact => 1 });

=cut

sub compact {
    my ($self, $data) = @_;

    $self->_check_db($data);

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
attachement to an existing doc if the '_id' parameter is given or creates
a new empty doc with the attachement otherwise.
The 'file' and 'filename' parameters are mandatory.

    my ($id, $rev) = $sc->put_file({ file => 'content', filename => 'file.txt', id => 'doc_id' });

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

    $self->_check_db($data);

    my $id  = $data->{id}  || $data->{doc}->{_id};
    my $rev = $data->{rev} || $data->{doc}->{_rev};

    if (!$rev && $id) {
        $rev = $self->head_doc($id);
        $self->_log("put_file(): rev $rev") if $self->debug;
    }

    # create a new doc if required
    ($id, $rev) = $self->put_doc({ doc => {} }) unless $id;

    my $path = $self->db . '/' . $id . '/' . $data->{filename} . '?rev=' . $rev;

    $self->method('PUT');
    $data->{content_type} ||= 'text/plain';
    my $res = $self->_call($path, $data->{file}, $data->{content_type});

    return ($res->{id}, $res->{rev}) if wantarray;
    return $res->{id};
}

=head2 get_file

Get a file attachement from a CouchDB document.

    my $content = $sc->get_file({ id => 'doc_id', filename => 'file.txt' });

=cut

sub get_file {
    my ($self, $data) = @_;

    $self->_check_db($data);

    unless ($data->{id}) {
        carp "Document ID not defined";
        return;
    }
    unless ($data->{filename}) {
        carp "File name not defined";
        return;
    }

    my $path = join('/', $self->db, $data->{id}, $data->{filename});

    $self->method('GET');

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

    my $result = $sc->create_db('name');

=cut

sub create_db {
    my ($self, $db) = @_;

    if ($db) {
        $self->db($db);
    }

    $self->method('PUT');
    my $res = $self->_call($self->db);

    return $res;
}

=head2 delete_db

Delete/Drop a Databse

    my $result = $sc->delete_db('name');

=cut

sub delete_db {
    my ($self, $db) = @_;

    if ($db) {
        $self->db($db);
    }

    $self->method('DELETE');
    my $res = $self->_call($self->db);

    return $res;
}

=head2 all_dbs

Get a list of all Databases

    my @db = $sc->all_dbs;

=cut

sub all_dbs {
    my ($self) = @_;

    $self->method('GET');
    my $res = $self->_call('_all_dbs');

    return @{ $res || [] };
}

sub _check_db {
    my ($self, $data) = @_;

    if (    ref $data eq 'HASH'
        and exists $data->{dbname}
        and defined $data->{dbname})
    {
        $self->db($data->{dbname});
        return;
    }

    unless ($self->has_db) {
        carp 'database not defined! you must set $sc->db("some_database")';
        return;
    }

    return;
}

sub _make_path {
    my ($self, $data) = @_;

    my ($design, $view, $show, $list);

    if (exists $data->{view}) {
        $data->{view} =~ s/^\///;
        ($design, $view) = split(/\//, $data->{view}, 2);
    }

    if (exists $data->{show}) {
        $data->{show} =~ s/^\///;
        ($design, $show) = split(/\//, $data->{show}, 2);
    }

    $list = $data->{list} if exists $data->{list};

    my $path = $self->db . "/_design/${design}";
    if ($list) {
        $path .= "/_list/${list}/${view}";
    }
    elsif ($show) {
        $path .= "/_show/${show}";
    }
    elsif ($view) {
        $path .= "/_view/${view}";
    }

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

    binmode(STDERR, ":encoding(UTF-8)") if $self->debug;

    # cleanup old error
    $self->clear_error if $self->has_error;

    my $uri = ($self->ssl) ? 'https://' : 'http://';
    $uri .= $self->user . ':' . $self->pass . '@'
        if ($self->user and $self->pass);
    $uri .= $self->host . ':' . $self->port . '/' . $path;

    $self->_log($self->method . ": $uri") if $self->debug;

    my $req = HTTP::Request->new();
    $req->method($self->method);
    $req->uri($uri);

    if ($content) {
        if ($self->debug) {
            $self->_log('Payload: ' . $self->_dump($content));
        }
        $req->content((
                  $ct
                ? $content
                : $self->json->encode($content)));
    }

    my $ua = LWP::UserAgent->new(timeout => $self->timeout);

    $ua->default_header('Content-Type' => $ct || "application/json");
    my $res = $ua->request($req);

    if ($self->debug) {
        my $dc = $res->decoded_content;
        chomp $dc;
        $self->_log('Result: ' . $self->_dump($dc));
    }

    if ($self->method eq 'HEAD') {
        $self->_log('Revision: ' . $res->header('ETag')) if $self->debug;
        return $res->header('ETag') || undef;
    }
    elsif ($res->is_success) {
        my $result;
        eval { $result = $self->json->decode($res->content) };
        return $result unless $@;
        return {
            file         => $res->decoded_content,
            content_type => [ $res->content_type ]->[0],
        };
    }
    else {
        $self->error($res->status_line);
    }

    return;
}

sub _hash {
    my ($self, $head, $val, @tail) = @_;

    if ($#tail == 0) {
        return $head->{ shift(@tail) } = $val;
    }
    else {
        return $self->_hash($head->{ shift(@tail) } //= {}, $val, @tail);
    }
}

sub _dump {
    my ($self, $obj) = @_;

    my %options;
    if ($self->debug) {
        $options{colored} = 1;
    }
    else {
        $options{colored}   = 0;
        $options{multiline} = 0;
    }

    require Data::Printer;
    Data::Printer->import(%options) unless __PACKAGE__->can('p');

    my $dump;
    if (ref $obj) {
        $dump = p($obj, %options);
    }
    else {
        $dump = p(\$obj, %options);
    }

    return $dump;
}

sub _log {
    my ($self, $msg) = @_;

    print STDERR __PACKAGE__ . ': ' . $msg . $/;

    return;
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
