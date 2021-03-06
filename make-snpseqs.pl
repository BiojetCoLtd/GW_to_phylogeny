#!/usr/bin/perl
use strict;
use Getopt::Long qw(:config posix_default no_ignore_case bundling auto_help);
use FindBin qw($Script);
use Text::CSV_XS;
use DBI;

sub usage
{
    die "$Script --db-file filename.db --strains strain1[,strain2[, ...]] --type {strict|allow-gaps|reference} [--min-coverage N] [--max-coverage N] --snp-pos-file filename.csv --out filename.fasta --summary filename.txt\n";
}

my ($db_file, $strains_str, $type, $min_cov, $max_cov, $csv_file, $fasta_file, $summary_file);
GetOptions(
    'db-file|d=s'      => \$db_file,
    'strains|s=s'      => \$strains_str,
    'type|t=s'         => \$type,
    'min-coverage|m=i' => \$min_cov,
    'max-coverage|x=i' => \$max_cov,
    'snp-pos-file|p=s' => \$csv_file,
    'out|o=s'          => \$fasta_file,
    'summary|y=s'      => \$summary_file
);

if (! $db_file or ! $csv_file or ! $fasta_file) {
    usage();
}
$type = 'allow-gaps' if(! $type);
$min_cov = 5 if (! $min_cov);
$max_cov = 99999 if (! $max_cov);
if (! grep {$_ eq $type} qw(strict allow-gaps reference)) {
    usage();
}

my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", "", "", {
    PrintError => 0, RaiseError => 1, ShowErrorStatement => 1});
die "Cannot open database file: ${db_file}\n" if (! $dbh);

my @target_strains;
get_strains($dbh, \@target_strains, $strains_str);

open(my $in_fp, '<', $csv_file) || die "$!: $csv_file\n";
my $csv = Text::CSV_XS->new({
    'quote_char'   => '"',
    'escape_char'  => '"',
    'always_quote' => 1,
    'binary'       => 1});

my %contigs;
my @contig_order;
my %punch;

my $line_num = 1;;
my %column_idx;

my $header = <$in_fp>;
if (! $csv->parse($header)) {
    die "CSV parse error at line ${line_num}\n";
}
my @t = $csv->fields();
foreach my $col ("Chromosome", "Region", "Type", "Reference", "Reference allele" ,"Length", 
		 "Zygosity", "Origin tracks") {
    my ($col_num) = grep { $t[$_] eq $col } 0 .. $#t;
    $column_idx{$col} = $col_num;
}

while(<$in_fp>) {
    $line_num++;
    if (! $csv->parse($_)) {
	die "CSV parse error at line ${line_num}\n";
    }
    my @elem = $csv->fields();
    my %dat;
    foreach my $col_name (keys %column_idx) {
	$dat{$col_name} = $elem[$column_idx{$col_name}];
    }
    next if ($dat{"Type"} ne 'SNV' or $dat{"Zygosity"} ne 'Homozygous');
    next if ($dat{"Region"} !~ /^\d+$/);
    next if ($dat{"Length"} ne '1');
    next if ($dat{"Reference"} !~ /^[ATGC]$/);
    if (! exists($contigs{$dat{"Chromosome"}})) {
	push @contig_order, $dat{"Chromosome"};
	$contigs{$dat{"Chromosome"}} = 1;
    }
    $punch{$dat{"Chromosome"}}->{$dat{"Region"}} = { "ref" => $dat{"Reference"} };
}

my $sth_select_str_nuc = $dbh->prepare(
    "SELECT strains.name, str_nucs.nucleotide, str_nucs.coverage FROM str_nucs, strains, contigs ".
    "WHERE str_nucs.strain_id=strains.id AND str_nucs.contig_id=contigs.id ".
    "AND contigs.name=? AND str_nucs.position=?");

foreach my $contig (@contig_order) {
    foreach my $pos (sort {$a <=> $b} keys %{$punch{$contig}}) {
	my ($num_valids, $num_differences) = (0, 0);
	$sth_select_str_nuc->bind_param(1, $contig);
	$sth_select_str_nuc->bind_param(2, $pos);
	$sth_select_str_nuc->execute();
	while (my $ref = $sth_select_str_nuc->fetchrow_arrayref ){
	    my ($strain, $nuc, $depth) = @{$ref};
	    next if (! grep {$_ eq $strain} @target_strains);
	    if ($nuc =~ /^[ATGC]$/ and $depth >= $min_cov and $depth <= $max_cov) {
		$punch{$contig}->{$pos}->{"tracks"}->{$strain} = $nuc;
		$num_differences++ if ($nuc ne $punch{$contig}->{$pos}->{'ref'});
		$num_valids++;
	    }
	}
	$punch{$contig}->{$pos}->{"num_valids"} = $num_valids;

	$punch{$contig}->{$pos}->{"num_differences"} = $num_differences;
    }
}
make_output_fasta($fasta_file, \@contig_order, \@target_strains, \%punch, $type);
make_summary_file($summary_file, \@contig_order, \@target_strains, \%punch ) if ($summary_file);

exit;


sub get_strains
{
    my ($dbh, $p_strains, $strains_str) = @_;
    my $sth;
    if ($strains_str) {
 	foreach my $strain (split(/,/, $strains_str)) {
	    $sth = $dbh->prepare('SELECT id FROM strains WHERE name=?');
	    
	    $sth->execute($strain);
	    if (! $sth->fetchrow_arrayref) {
		die "strain $strain does not exist in the database.\n";
	    }
	    push @{$p_strains}, $strain;
	}
    } else {
	$sth = $dbh->prepare('SELECT name FROM strains ORDER BY id');
	$sth->execute();
	while (my $ref = $sth->fetchrow_arrayref ){
	    my ($strain) = @{$ref};
	    push @{$p_strains}, $strain;
	}
    }
}

sub make_output_fasta
{
    my %seqs;
    my $fasta_line_length = 50;
    
    my ($fasta_file, $p_contig_order, $p_target_strains, $p_punch, $type) = @_;
    my $num_targets = scalar(@{$p_target_strains});
    
    foreach my $contig (@{$p_contig_order}) {
	foreach my $pos ( sort {$a <=> $b} keys %{$p_punch->{$contig}}) {
	    my @elems = ($contig, $pos);
	    my $ref = $p_punch->{$contig}->{$pos}->{'ref'};
	    my $num_valids = $p_punch->{$contig}->{$pos}->{'num_valids'};
	    my $num_differences = $p_punch->{$contig}->{$pos}->{'num_differences'};
	    if ($type =~ /^strict$/i) {
		next if ($num_valids != $num_targets);
		next if ($num_differences == 0);
	    }
	    next if ($num_valids == 0);
	    foreach my $strain (@{$p_target_strains}) {
		if (exists($p_punch->{$contig}->{$pos}->{"tracks"}->{$strain})) {
		    $seqs{$strain} .= $p_punch->{$contig}->{$pos}->{"tracks"}->{$strain};
		} else {
		    $seqs{$strain} .= $type eq 'allow-gaps' ? '-' : $ref;
		}
	    }
	}
    }
    open(my $out_fp, '>', $fasta_file) || die "$!: $fasta_file\n";
    foreach my $strain (@{$p_target_strains}) {
	print $out_fp ">${strain}\n";
	for (my $i = 0; $i < length($seqs{$strain}) ; $i += $fasta_line_length) {
	    print $out_fp substr($seqs{$strain}, $i, $fasta_line_length) . "\n";
	}
    }
}

sub make_summary_file
{
    my ($summary_file, $p_contig_order, $p_target_strains, $p_punch) = @_;
    open(my $out_fp, '>', $summary_file) || die "$!: $summary_file\n";

    print $out_fp join("\t", qw(CHROM POS REF #VALIDS #DIFFS), @{$p_target_strains}) . "\n";
    foreach my $contig (@{$p_contig_order}) {
	foreach my $pos ( sort {$a <=> $b} keys %{$p_punch->{$contig}}) {
	    my @elems = ($contig, $pos);
	    push @elems, $p_punch->{$contig}->{$pos}->{'ref'};
	    push @elems, $p_punch->{$contig}->{$pos}->{'num_valids'};
	    push @elems, $p_punch->{$contig}->{$pos}->{'num_differences'};
	    foreach my $strain (@{$p_target_strains}) {
		if (exists($p_punch->{$contig}->{$pos}->{"tracks"}->{$strain})) {
		    push @elems, $p_punch->{$contig}->{$pos}->{"tracks"}->{$strain};
		} else {
		    push @elems, '-';
		}
	    }
	    print $out_fp join("\t", @elems) . "\n";
	}
    }
}
