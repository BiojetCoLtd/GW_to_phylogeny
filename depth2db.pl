#!/usr/bin/perl
use strict;
use Getopt::Long qw(:config posix_default no_ignore_case bundling auto_help);
use FindBin qw($Script);
use Term::ReadKey;
use DBI;

sub usage
{
    die "$Script --db-file filename.db [--yes] strain1=strain1.tsv [strain2=strain2.tsv ..]\n";
}

my ($db_file, $overwrite_yes);
GetOptions(
    'db-file|d=s' => \$db_file,
    'yes|y' => \$overwrite_yes,
    );

if (! $db_file ) {
    usage();
}
my $dbh;
$dbh = new_db($db_file, $overwrite_yes);
$dbh->do("PRAGMA foreign_keys = ON");

eval {
    my %strain_ids;
    my %contig_ids;
    my $sth_insert_strain = $dbh->prepare("INSERT INTO strains(name) VALUES(?)");
    my $sth_insert_contig = $dbh->prepare("INSERT INTO contigs(name) VALUES(?)");
    my $sth_select_contig = $dbh->prepare("SELECT id FROM contigs WHERE name=?");
    my $sth_insert_str_nuc = $dbh->prepare("INSERT INTO str_nucs(strain_id, contig_id, ".
					   "position, nucleotide, coverage) ".
					   "VALUES (?,?,?,?,?)");
    foreach my $t (@ARGV) {
	my ($strain, $depth_file) = ($t =~ /^([^=]+)=(.+)/);
	open(my $fp, $depth_file) || die "$!: $depth_file\n";
	my $strain_id;
	if (! exists($strain_ids{$strain})) {
	    $sth_insert_strain->execute($strain);
	    $strain_id = $dbh->sqlite_last_insert_rowid();
	    $strain_ids{$strain} = $strain_id;
	} else {
	    die "Duplicate strain: ${strain}\n";
	}

	$| = 1;
	print "Processing ${depth_file} ";
	my $num_line = 0;
        my ($prev_contig, $prev_pos) = ('', -1);
	while(my $line = <$fp>) {
	    if ($num_line % 1000000 == 0) {
		print '.';
	    }
	    $num_line++;

	    $line =~ s/[\r\n]//g;
	    my ($contig, $pos, $subpos, $ref, $numA, $numC, $numG, $numT, $numN, $numGap,
		$total) = split(/\t/, $line);
	    next if (($contig eq $prev_contig) and ($pos eq $prev_pos));
	    ($prev_contig, $prev_pos) = ($contig, $pos);
	    my $contig_id;
	    next if ($subpos ne '-');
	    if (! exists($contig_ids{$contig})) {
		$sth_select_contig->bind_param(1, $contig);
		$sth_select_contig->execute();
		my $res = $sth_select_contig->fetchrow_arrayref;
		if ($res) {
		    ($contig_id) = @{$res};
		} else {
		    $sth_insert_contig->execute($contig);
		    $contig_id = $dbh->sqlite_last_insert_rowid();
		}
		$contig_ids{$contig} = $contig_id;
	    } else {
		$contig_id = $contig_ids{$contig};
	    }
	    my ($max_nuc, $max_depth) = ('.', 0);
	    ($max_nuc, $max_depth) = ('A', $numA) if ($numA > $max_depth);
	    ($max_nuc, $max_depth) = ('C', $numC) if ($numC > $max_depth);
	    ($max_nuc, $max_depth) = ('G', $numG) if ($numG > $max_depth);
	    ($max_nuc, $max_depth) = ('T', $numT) if ($numT > $max_depth);
	    ($max_nuc, $max_depth) = ('N', $numN) if ($numN > $max_depth);
	    ($max_nuc, $max_depth) = ('-', $numGap) if ($numGap > $max_depth);
	    $sth_insert_str_nuc->execute($strain_id, $contig_id, $pos, $max_nuc, $max_depth);
	}
	print "done\n";
    }
    print "Creating index ...";
    $dbh->do("CREATE INDEX str_nucs_idx ON str_nucs(contig_id, position)");
    print "done\n";
    $| = 0;
    $dbh->commit();
};
if ($@) {
    $dbh->rollback();
    die "$@\n";
}

sub new_db
{
    my ($db_file, $overwrite_yes) = @_;

    if (-f $db_file) {
	if (! $overwrite_yes) {
	    print "${db_file} already exists. overwirte? [N]:";
	    ReadMode 'normal';
	    chomp(my $line = ReadLine 0);
	    ReadMode 'restore';
	    if ($line !~ /^Y(es)?$/i) {
		exit;
	    }
	}
	unlink $db_file;
    }

    my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", "", "", {
	PrintError => 0, RaiseError => 1, ShowErrorStatement => 1,
	AutoCommit => 0});

    eval {
	$dbh->do("CREATE TABLE strains(id INTEGER PRIMARY KEY, ".
		 "name VARCHAR(50) UNIQUE NOT NULL)");
	$dbh->do("CREATE TABLE contigs(id INTEGER PRIMARY KEY, ".
		 "name VARCHAR(50) UNIQUE NOT NULL)");
	$dbh->do("CREATE TABLE str_nucs(strain_id INTEGER REFERENCES strains(id), ".
		 "contig_id INTEGER REFERENCES contigs(id), position INTEGER NOT NULL, " .
		 "nucleotide CHAR(1), coverage INTEGER NOT NULL)");
	$dbh->commit();
    };
    if ($@) {
	$dbh->rollback();
	die "$@\n";
    }
    return $dbh;
}
