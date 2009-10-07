use inc::Module::Install;

name     'Store-CouchDB';
all_from 'lib/Store/CouchDB.pm';
author   q{Lenz Gschwendtner <norbu09@cpan.org>};
license  'perl';

requires 'Moose';
requires 'JSON';
requires 'LWP::UserAgent';
requires 'URI';

build_requires 'Test::More';

auto_install;

WriteAll;

