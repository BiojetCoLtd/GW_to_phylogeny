# GW_to_phylogeny : Create nucleotide sequences in which bases of SNPs of each strain are collected for use in phylogenetic analysis.

---

## Acceptable input formats:

+ Per-base information on coverage exported as tsv format on CLC Genomics Workbench.
+ Annotation and variant information exported as csv format on CLC Genomics Workbench.

## Required libraries and programs:

+ Perl5 (Tested on 5.22.1)
+ SQLite3
+ Perl module DBI
+ Perl module DBD::SQLite
+ Perl module Term::ReadKey
+ Perl module Text::CSV_XS

## Usage:

```
   depth2db.pl --db-file filename.db [--yes] strain1=strain1.tsv [strain2=strain2.tsv ..]

Options:
   --db-file : SQLite db file

   --yes : do not prompt before overwriting
```

```
   make-snpseqs.pl --db-file filename.db --strains strain1[,strain2[, ...]] \
   --type {strict|allow-gaps|reference} [--min-coverage N] [--max-coverage N] \
   --snp-pos-file filename.csv --out filename.fasta --summary filename.txt  

Options:
   --db-file : SQLite db file

   --strains : comma separated strain list to process

   --type : processing method for SNPs without relevant depth
   
   --min-coverage : minimum coverage
   
   --max-coverage : maximum coverage
   
   --snp-pos-file : annotation and variant csv file
   
   --out : output fasta file

   --summary : processing report
```
