# Sets up a KDC and then runs a variety of tests to make sure that the
# GSSAPI/Kerberos authentication and encryption are working properly,
# that the options in pg_hba.conf and pg_ident.conf are handled correctly,
# and that the server-side pg_stat_gssapi view reports what we expect to
# see for each test.
#
# Since this requires setting up a full KDC, it doesn't make much sense
# to have multiple test scripts (since they'd have to also create their
# own KDC and that could cause race conditions or other problems)- so
# just add whatever other tests are needed to here.
#
# See the README for additional information.

use strict;
use warnings;
use TestLib;
use PostgresNode;
use Test::More;

if ($ENV{with_gssapi} eq 'yes')
{
	plan tests => 13;
}
else
{
	plan skip_all => 'GSSAPI/Kerberos not supported by this build';
}

my ($krb5_bin_dir, $krb5_sbin_dir);

if ($^O eq 'darwin')
{
	$krb5_bin_dir  = '/usr/local/opt/krb5/bin';
	$krb5_sbin_dir = '/usr/local/opt/krb5/sbin';
}
elsif ($^O eq 'freebsd')
{
	$krb5_bin_dir  = '/usr/local/bin';
	$krb5_sbin_dir = '/usr/local/sbin';
}
elsif ($^O eq 'linux')
{
	$krb5_sbin_dir = '/usr/sbin';
}

my $krb5_config  = 'krb5-config';
my $kinit        = 'kinit';
my $kdb5_util    = 'kdb5_util';
my $kadmin_local = 'kadmin.local';
my $krb5kdc      = 'krb5kdc';

if ($krb5_bin_dir && -d $krb5_bin_dir)
{
	$krb5_config = $krb5_bin_dir . '/' . $krb5_config;
	$kinit       = $krb5_bin_dir . '/' . $kinit;
}
if ($krb5_sbin_dir && -d $krb5_sbin_dir)
{
	$kdb5_util    = $krb5_sbin_dir . '/' . $kdb5_util;
	$kadmin_local = $krb5_sbin_dir . '/' . $kadmin_local;
	$krb5kdc      = $krb5_sbin_dir . '/' . $krb5kdc;
}

my $host     = 'auth-test-localhost.postgresql.example.com';
my $hostaddr = '127.0.0.1';
my $realm    = 'EXAMPLE.COM';

my $krb5_conf   = "${TestLib::tmp_check}/krb5.conf";
my $kdc_conf    = "${TestLib::tmp_check}/kdc.conf";
my $krb5_log    = "${TestLib::tmp_check}/krb5libs.log";
my $kdc_log     = "${TestLib::tmp_check}/krb5kdc.log";
my $kdc_port    = int(rand() * 16384) + 49152;
my $kdc_datadir = "${TestLib::tmp_check}/krb5kdc";
my $kdc_pidfile = "${TestLib::tmp_check}/krb5kdc.pid";
my $keytab      = "${TestLib::tmp_check}/krb5.keytab";

note "setting up Kerberos";

my ($stdout, $krb5_version);
run_log [ $krb5_config, '--version' ], '>', \$stdout
  or BAIL_OUT("could not execute krb5-config");
BAIL_OUT("Heimdal is not supported") if $stdout =~ m/heimdal/;
$stdout =~ m/Kerberos 5 release ([0-9]+\.[0-9]+)/
  or BAIL_OUT("could not get Kerberos version");
$krb5_version = $1;

append_to_file(
	$krb5_conf,
	qq![logging]
default = FILE:$krb5_log
kdc = FILE:$kdc_log

[libdefaults]
default_realm = $realm

[realms]
$realm = {
    kdc = $hostaddr:$kdc_port
}!);

append_to_file(
	$kdc_conf,
	qq![kdcdefaults]
!);

# For new-enough versions of krb5, use the _listen settings rather
# than the _ports settings so that we can bind to localhost only.
if ($krb5_version >= 1.15)
{
	append_to_file(
		$kdc_conf,
		qq!kdc_listen = $hostaddr:$kdc_port
kdc_tcp_listen = $hostaddr:$kdc_port
!);
}
else
{
	append_to_file(
		$kdc_conf,
		qq!kdc_ports = $kdc_port
kdc_tcp_ports = $kdc_port
!);
}
append_to_file(
	$kdc_conf,
	qq!
[realms]
$realm = {
    database_name = $kdc_datadir/principal
    admin_keytab = FILE:$kdc_datadir/kadm5.keytab
    acl_file = $kdc_datadir/kadm5.acl
    key_stash_file = $kdc_datadir/_k5.$realm
}!);

mkdir $kdc_datadir or die;

$ENV{'KRB5_CONFIG'}      = $krb5_conf;
$ENV{'KRB5_KDC_PROFILE'} = $kdc_conf;

my $service_principal = "$ENV{with_krb_srvnam}/$host";

system_or_bail $kdb5_util, 'create', '-s', '-P', 'secret0';

my $test1_password = 'secret1';
system_or_bail $kadmin_local, '-q', "addprinc -pw $test1_password test1";

system_or_bail $kadmin_local, '-q', "addprinc -randkey $service_principal";
system_or_bail $kadmin_local, '-q', "ktadd -k $keytab $service_principal";

system_or_bail $krb5kdc, '-P', $kdc_pidfile;

END
{
	kill 'INT', `cat $kdc_pidfile` if -f $kdc_pidfile;
}

note "setting up PostgreSQL instance";

my $node = get_new_node('node');
$node->init;
$node->append_conf('postgresql.conf', "listen_addresses = '$hostaddr'");
$node->append_conf('postgresql.conf', "krb_server_keyfile = '$keytab'");
$node->start;

$node->safe_psql('postgres', 'CREATE USER test1;');

note "running tests";

sub test_access
{
	my ($node, $role, $server_check, $expected_res, $gssencmode, $test_name)
	  = @_;

	# need to connect over TCP/IP for Kerberos
	my ($res, $stdoutres, $stderrres) = $node->psql(
		'postgres',
		"$server_check",
		extra_params => [
			'-XAtd',
			$node->connstr('postgres')
			  . " host=$host hostaddr=$hostaddr $gssencmode",
			'-U',
			$role
		]);

	# If we get a query result back, it should be true.
	if ($res == $expected_res and $res eq 0)
	{
		is($stdoutres, "t", $test_name);
	}
	else
	{
		is($res, $expected_res, $test_name);
	}
	return;
}

unlink($node->data_dir . '/pg_hba.conf');
$node->append_conf('pg_hba.conf',
	qq{host all all $hostaddr/32 gss map=mymap});
$node->restart;

test_access($node, 'test1', 'SELECT true', 2, '', 'fails without ticket');

run_log [ $kinit, 'test1' ], \$test1_password or BAIL_OUT($?);

test_access($node, 'test1', 'SELECT true', 2, '', 'fails without mapping');

$node->append_conf('pg_ident.conf', qq{mymap  /^(.*)\@$realm\$  \\1});
$node->restart;

test_access(
	$node,
	'test1',
	'SELECT gss_authenticated AND encrypted from pg_stat_gssapi where pid = pg_backend_pid();',
	0,
	'',
	'succeeds with mapping with default gssencmode and host hba');
test_access(
	$node,
	"test1",
	'SELECT gss_authenticated AND encrypted from pg_stat_gssapi where pid = pg_backend_pid();',
	0,
	"gssencmode=prefer",
	"succeeds with GSS-encrypted access preferred with host hba");
test_access(
	$node,
	"test1",
	'SELECT gss_authenticated AND encrypted from pg_stat_gssapi where pid = pg_backend_pid();',
	0,
	"gssencmode=require",
	"succeeds with GSS-encrypted access required with host hba");

unlink($node->data_dir . '/pg_hba.conf');
$node->append_conf('pg_hba.conf',
	qq{hostgssenc all all $hostaddr/32 gss map=mymap});
$node->restart;

test_access(
	$node,
	"test1",
	'SELECT gss_authenticated AND encrypted from pg_stat_gssapi where pid = pg_backend_pid();',
	0,
	"gssencmode=prefer",
	"succeeds with GSS-encrypted access preferred and hostgssenc hba");
test_access(
	$node,
	"test1",
	'SELECT gss_authenticated AND encrypted from pg_stat_gssapi where pid = pg_backend_pid();',
	0,
	"gssencmode=require",
	"succeeds with GSS-encrypted access required and hostgssenc hba");
test_access($node, "test1", 'SELECT true', 2, "gssencmode=disable",
	"fails with GSS encryption disabled and hostgssenc hba");

unlink($node->data_dir . '/pg_hba.conf');
$node->append_conf('pg_hba.conf',
	qq{hostnogssenc all all $hostaddr/32 gss map=mymap});
$node->restart;

test_access(
	$node,
	"test1",
	'SELECT gss_authenticated and not encrypted from pg_stat_gssapi where pid = pg_backend_pid();',
	0,
	"gssencmode=prefer",
	"succeeds with GSS-encrypted access preferred and hostnogssenc hba, but no encryption"
);
test_access($node, "test1", 'SELECT true', 2, "gssencmode=require",
	"fails with GSS-encrypted access required and hostnogssenc hba");
test_access(
	$node,
	"test1",
	'SELECT gss_authenticated and not encrypted from pg_stat_gssapi where pid = pg_backend_pid();',
	0,
	"gssencmode=disable",
	"succeeds with GSS encryption disabled and hostnogssenc hba");

# Greenplum tests for expiration, remove if upstream adds the similar tests
# Rewrite the pg_hba.conf to allow us doing the "ALTER USER" commands
unlink($node->data_dir . '/pg_hba.conf');
$node->append_conf('pg_hba.conf', qq{local all all trust});
$node->append_conf('pg_hba.conf', qq{host all all all trust});
$node->restart;

$node->safe_psql('postgres', q{ALTER USER test1 VALID UNTIL '2001-01-01 01:00:00-00'});

unlink($node->data_dir . '/pg_hba.conf');
$node->append_conf('pg_hba.conf',
	qq{hostgssenc all all $hostaddr/32 gss map=mymap});
$node->restart;

test_access(
	$node,
	"test1",
	'SELECT true',
	2,
	"gssencmode=prefer",
	"fails with user expired");

unlink($node->data_dir . '/pg_hba.conf');
$node->append_conf('pg_hba.conf', qq{local all all trust});
$node->append_conf('pg_hba.conf', qq{host all all all trust});
$node->restart;

$node->safe_psql('postgres', q{ALTER USER test1 VALID UNTIL '2099-12-31 23:00:00-00'});
# Following tests should succeed with user not expired

truncate($node->data_dir . '/pg_ident.conf', 0);
unlink($node->data_dir . '/pg_hba.conf');
$node->append_conf('pg_hba.conf',
	qq{host all all $hostaddr/32 gss include_realm=0});
$node->restart;

test_access(
	$node,
	'test1',
	'SELECT gss_authenticated AND encrypted from pg_stat_gssapi where pid = pg_backend_pid();',
	0,
	'',
	'succeeds with include_realm=0 and defaults');
