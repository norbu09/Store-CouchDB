#!perl

use strict;
use warnings;
use Test::More tests => 22;

BEGIN { use_ok('Store::CouchDB'); }

use Store::CouchDB;
use Scalar::Util qw(looks_like_number);

my $sc      = Store::CouchDB->new();
my $db      = 'test' . int(rand(100) + 100);
my $cleanup = 0;

# use delete DB to figure out whether we can connect to CouchDB
# and clean out test DB if exists.
$sc->delete_db($db);

SKIP: {
    skip 'needs admin party CouchDB on localhost:5984', 21
        if ($sc->has_error and $sc->error !~ m/Object Not Found/);

    # operate on test DB from now on
    $sc->db($db);

    my $result = $sc->create_db();
    ok($result->{ok} == 1, "create DB $db");

    # trigger DB removal on exit as last test
    $cleanup = 1 if $result->{ok} == 1;

    # all DBs
    my @db = $sc->all_dbs;
    ok((grep { $_ eq $db } @db), 'get all databases');

    # create doc (array return)
    my ($id, $rev) = $sc->put_doc({ doc => { key => 'value' } });
    ok(($id and $rev =~ m/^1-/), 'create document (array return)');

    # head doc
    $rev = $sc->head_doc($id);
    ok($rev =~ /^1-/, 'get document head');

    # get doc
    my $doc = $sc->get_doc({ id => $id });
    is_deeply($doc, { _id => $id, _rev => $rev, key => 'value' },
        "get document");

    # create design doc for show/view/list tests
    $result = $sc->put_doc({
            doc => {
                _id      => '_design/test',
                language => 'javascript',
                lists    => {
                    list =>
                        'function(head, req) { var row; var result = []; start({ "headers": { "Content-Type": "application/json"}}); while (row = getRow()) { result.push(row.key); } return JSON.stringify(result); }'
                },
                views => {
                    view => {
                        map    => 'function(doc) { emit(doc.key, 2); }',
                        reduce => '_count',
                    }
                },
                shows => {
                    show =>
                        'function(doc, req) { return JSON.stringify(doc.key); }',
                },
            },
        });
    ok($result, 'create design doc');

    # show doc
    $result = $sc->show_doc({ id => $id, show => 'test/show' });
    ok($result eq 'value', 'show document');

    # update doc
    ($id, $rev) = $sc->put_doc(
        { doc => { _id => $id, _rev => $rev, key => "newvalue" } });
    ok(($id and $rev =~ m/2-/), "update document");

    # copy doc
    my ($copy_id, $copy_rev) = $sc->copy_doc($id);
    ok(($copy_id and $copy_rev =~ m/1-/), "copy document");

    # delete doc
    $copy_rev = $sc->del_doc($copy_id);
    ok(($copy_rev =~ m/2-/), "delete document");

    # get design docs
    $result = $sc->get_design_docs;
    is_deeply($result, ['test'], 'get design documents');

    # get view
    $result =
        $sc->get_view({ view => 'test/view', opts => { reduce => 'false' } });
    is_deeply($result, { newvalue => 2 }, 'get view (plain)');

    # get view reduce
    $result =
        $sc->get_view({ view => 'test/view', opts => { reduce => 'true' } });
    is_deeply($result, { 0 => 1 }, 'get view (reduce)');

    # list view
    $result = $sc->list_view({
            view => 'test/view',
            list => 'list',
            opts => { reduce => 'false' } });
    is_deeply($result, ['newvalue'], 'list view');

    # get array view
    $result = $sc->get_array_view(
        { view => 'test/view', opts => { reduce => 'false' } });
    is_deeply(
        $result,
        [ { id => $id, key => 'newvalue', value => 2 } ],
        'get array view'
    );

    # purge
    $result = $sc->purge();
    is_deeply(
        $result, {
            5 => {
                purge_seq => 1,
                purged    => { $copy_id => [$copy_rev] },
            },
        },
        'purge'
    );

    # compact
    $result = $sc->compact({ purge => 1, view_compact => 1 });
    ok((
                    $result->{compact}->{ok} == 1
                and $result->{test_compact}->{ok} == 1
                and $result->{view_compact}->{ok} == 1
        ),
        "purge DB, compact views and DB"
    );

    # put file
    ($id, $rev) =
        $sc->put_file({ file => 'content', filename => 'file.txt' });
    ok(($id and $rev =~ m/2-/), "create attachment");

    # get file
    $result = $sc->get_file({ id => $id, filename => 'file.txt' });
    is_deeply(
        $result,
        { file => 'content', content_type => 'text/plain' },
        'get attachment'
    );

    # create doc (single variable return)
    my $newid = $sc->put_doc({ doc => { key => 'somevalue' } });
    ok(($newid and $newid !~ m/^1-/), 'create document');
}

END {
    if ($cleanup) {
        my $result = $sc->delete_db();
        ok($result->{ok} == 1, 'delete DB');
    }

    done_testing();
}
