
# This script looks for any minor allele frequencies of 0.5
# and then ensures that the minor allele stored in the variation
# table is not the reference allele

use strict;
use warnings;

use Getopt::Long;

use Bio::EnsEMBL::Registry;

my $registry_file;
my $help;

GetOptions(
    "registry|r=s"  => \$registry_file,
    "help|h"        => \$help,
);

unless ($registry_file) {
    print "Must supply a registry file...\n" unless $help;
    $help = 1;
}

if ($help) {
    print "Usage: $0 --registry <reg_file>\n";
    exit(0);
}

my $registry = 'Bio::EnsEMBL::Registry';

$registry->load_all($registry_file);

my $dbh = $registry->get_adaptor(
    'human', 'variation', 'variation'
)->dbc->db_handle;

my $get_vars_sth = $dbh->prepare(qq{
    SELECT  v.variation_id, v.name, v.minor_allele
    FROM    variation v, variation_feature vf
    WHERE   v.minor_allele_freq = 0.5
    AND     v.variation_id = vf.variation_id
    AND     v.minor_allele = SUBSTR(vf.allele_string,1,1)
});

my $get_maf_sth = $dbh->prepare(qq{
    SELECT  allele
    FROM    maf
    WHERE   snp_id = ?
});

my $fix_maf_sth = $dbh->prepare(qq{
    UPDATE  variation
    SET     minor_allele = ?
    WHERE   variation_id = ?
});

$get_vars_sth->execute;

my $count = 0;

while (my ($v_id, $name, $old_allele) = $get_vars_sth->fetchrow_array) {
    
    $name =~ s/^rs//;
    $get_maf_sth->execute($name);
    
    my $new_allele;

    while (my ($allele) = $get_maf_sth->fetchrow_array) {
        if ($allele ne $old_allele) {
            $new_allele = $allele;
            last;
        }
    }

    die "Didn't find alternative minor allele for variation $v_id?" unless $new_allele;

    $count++;

    $fix_maf_sth->execute($new_allele, $v_id);
}

print "Corrected $count alleles\n";

