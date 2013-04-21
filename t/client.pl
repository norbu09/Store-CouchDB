#!/usr/bin/perl -Ilib

use strict;
use warnings;
use lib 'lib';
use Store::CouchDB;
use Data::Dumper;

my $db = Store::CouchDB->new();

$db->debug(1);
$db->host('127.0.0.1');

#my $doc = $db->get_doc(
#    { dbname => 'billing', id => '226f914db521a2d0f71c1b5f81c21aa4' } );
#print Dumper($doc);
#if ( $db->has_err ) {
#    print "ERR: " . $db->err . "\n";
#}

#my $record = {
#    user_id      => 'blubb',
#    payment_type => 'cc',
#    cc           => 'blubb',
#    platform     => ['iwantmyname'],
#    status       => 'virgin',
#    country      => 'blubb',
#    type         => 'user',
#    last4        => 'blubb',
#    username     => 'blubb',
#    address      => 'blubb',
#    blubb        => 'more blubb',
#};

#my $res = $db->put_doc( { dbname => "billing", doc => $record } );
#$doc->{lenz} = "more stuff here";
#delete $doc->{platform};
#$doc->{_rev} = '1-1432586889';

#my $req = {
#    dbname => 'post_test',
#    id => 'da860dcc8ab87f28a50282bbe801ebaf',
#    file => 'helo world2',
#    content_type => 'text/plain',
#    filename => 'test.txt'
#};
#my $res = $db->get_post_view($req);
#my $res = $db->put_file($req);
#my $res = $db->get_file($req);

print Dumper($db->create_db('blubb'));
if ( $db->error ) {
    print "ERR: " . $db->error . "\n";
}
