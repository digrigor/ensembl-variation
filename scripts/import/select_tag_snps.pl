#!/usr/local/ensembl/bin/perl
use strict;
use warnings;

use Getopt::Long;
use Bio::EnsEMBL::Variation::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Variation::DBSQL::LDFeatureContainerAdaptor;
use FindBin qw( $Bin );
use Data::Dumper;

my ($TMP_DIR, $population_id, $species);


GetOptions('species=s' => \$species,
	   'tmpdir=s'  => \$TMP_DIR,
	   'population_id=i' => \$population_id);

warn("Make sure you have a updated ensembl.registry file!\n");

my $registry_file ||= $Bin . "/ensembl.registry";

#added default options
$species ||= 'human';
Bio::EnsEMBL::Registry->load_all( $registry_file );

my $dbVariation = Bio::EnsEMBL::Registry->get_DBAdaptor($species,'variation');
my $dbCore = Bio::EnsEMBL::Registry->get_DBAdaptor($species,'core');

#first, copy the file locally
system("lsrcp ecs4a:$TMP_DIR/$ARGV[0] /tmp/$ARGV[0]");
#first, calculate the MAF for the SNPs in the chromosome
my $file = "/tmp/$ARGV[0]" if (defined @ARGV);
die "Not possible to calculate SNP tagging without file with SNPs" if (!defined @ARGV);

`sort -k 3 -o $file $file`; #order snps by position

open IN, "<$file" or die("Could not open input file: $file\n");

my $r2 = 0.99; #default value for r2

my $previous_seq_region_start = 0;
my ($allele_1, $allele_2, $seq_region_start);
my $genotypes_snp = {};
my $last_snp = 0; #to indicate if there is a last snp that needs the MAF calculation
my $MAF_snps = {};
while (<IN>){
    chomp;
    /^\#/ && next;
    ($allele_1, $allele_2, $seq_region_start) = split;
    #when we change variation_feature, calculate the MAF
    if (($previous_seq_region_start != $seq_region_start) && $previous_seq_region_start != 0){
	$MAF_snps->{$previous_seq_region_start} = &calculate_MAF($genotypes_snp) . '-' . $previous_seq_region_start;
	$genotypes_snp = {};
	$previous_seq_region_start = $seq_region_start;
	$last_snp = 1;

    }
    if ($previous_seq_region_start == 0){ #initialize the variables
	$previous_seq_region_start = $seq_region_start;
    }
    $genotypes_snp->{$allele_1}++ if ($allele_1 ne 'N');
    $genotypes_snp->{$allele_2}++ if ($allele_2 ne 'N');    
    $last_snp = 0;
}
close IN;

#calculate the MAF for the last SNP, if necessary
$MAF_snps->{$previous_seq_region_start} = &calculate_MAF($genotypes_snp) . '-' . $previous_seq_region_start if ($last_snp == 0);

#get LD values for the chromosome
$file =~/.*-(\d+)\.txt/; #extract the seq_region_id from the name of the file
my $seq_region_id = $1;
my $pos_to_vf = {};
my $host = `hostname`;
chop $host;
my $LD_values = &get_LD_chromosome($dbCore,$dbVariation,$seq_region_id,$r2,$population_id, $pos_to_vf);
#do the algorithm
my $remove_snps = {}; #hash containing the snps that must be removed from the entry, they have been ruled out
foreach $seq_region_start (sort {$MAF_snps->{$b} cmp $MAF_snps->{$a}} keys %{$MAF_snps}){
    if (!defined $remove_snps->{$seq_region_start}){
	#add the SNPs that should be removed in future iterations
	#and delete from the hash with the MAF_snps, the ones that have a r2 greater than r2 with $variation_feature_id
	map {$remove_snps->{$_}++;delete $MAF_snps->{$_}} @{$LD_values->{$seq_region_start}};
    }
}
my $genotype_without_vf = 0;
open OUT, ">/tmp/snps_tagged_$population_id\_$host\-$$\.txt" or die ("Could not open output file");
foreach my $position_vf (keys %{$MAF_snps}){
    if (! defined $pos_to_vf->{$position_vf}){ #some variations might not have LD, get dbID from database
	#get it from the database
	$pos_to_vf->{$position_vf} = &get_vf_id_from_position($dbCore,$dbVariation,$seq_region_id,$position_vf);
    }
    if ($pos_to_vf->{$position_vf} ne ''){
	print OUT join("\t",$pos_to_vf->{$position_vf},$population_id),"\n";
    }
    else{
	$genotype_without_vf++;
    }
}
print "Genotypes without vf $genotype_without_vf\n";
close OUT or die ("Could not close output file with tagged SNPs");
system("lsrcp /tmp/snps_tagged_$population_id\_$host\-$$\.txt ecs4a:$TMP_DIR/snps_tagged_$population_id\_$host\-$$\.txt");
system("rm -r /tmp/snps_tagged_$population_id\_$host\-$$\.txt");
system("rm -r $file");

#for a given position retrieve the vf_id from the database
sub get_vf_id_from_position{
    my $dbCore = shift;
    my $dbVariation = shift;
    my $seq_region_id = shift;
    my $seq_region_start = shift;

    my $slice_adaptor = $dbCore->get_SliceAdaptor;
    my $vf_adaptor = $dbVariation->get_VariationFeatureAdaptor;
    my $slice = $slice_adaptor->fetch_by_seq_region_id($seq_region_id); #get the Slice
    my $sub_Slice = $slice->sub_Slice($seq_region_start,$seq_region_start,1); 
    my $vfs = $vf_adaptor->fetch_all_by_Slice($sub_Slice) if (defined $sub_Slice);
    #there should be just one
    return $vfs->[0]->dbID if defined $vfs->[0];
    return ''; #no vf in the position ??
}
#for a list of genotypes, get the MAF
sub calculate_MAF{
    my $genotypes_snp = shift;
    my $MAF;
    my $total_genotypes = 0;
    my $allele_freq;

    if (keys %{$genotypes_snp} == 2){
	foreach (values %{$genotypes_snp}){
	    $total_genotypes += $_;
	    $allele_freq = ($_ / $total_genotypes) if ($total_genotypes != $_);
	}
	return $allele_freq if ($allele_freq <= (1 - $allele_freq));
	return 1 - $allele_freq if ($allele_freq > (1 - $allele_freq));
    }    
    return 0;
#    die "genotype with more than 2 alleles!!";
}

#creates a hash with all the variation_features in the chromosome with a r2 greater than r2
sub get_LD_chromosome{
    my $dbCore = shift;
    my $dbVariation = shift;
    my $seq_region_id = shift;
    my $r2 = shift;
    my $population_id = shift;
    my $pos_to_vf = shift;
    
    my $variation_features = {};
    my $ld_adaptor = $dbVariation->get_LDFeatureContainerAdaptor();
    my $slice_adaptor = $dbCore->get_SliceAdaptor;
    my $population_adaptor = $dbVariation->get_PopulationAdaptor;
    my $population = $population_adaptor->fetch_by_dbID($population_id); 
    my $slice = $slice_adaptor->fetch_by_seq_region_id($seq_region_id);
    my $ld_container = $ld_adaptor->fetch_by_Slice($slice, $population);
 #returns a list with vf1 vf2 r2 sample_id
    my ($vf1,$vf2);
    foreach my $ld_key (keys %{$ld_container->{'ldContainer'}}){
	foreach my $sample_id (keys %{$ld_container->{'ldContainer'}->{$ld_key}}){		    
	    ($vf1,$vf2) = split /-/, $ld_key;
	    $pos_to_vf->{$ld_container->{'variationFeatures'}->{$vf1}->start} = $vf1;
	    $pos_to_vf->{$ld_container->{'variationFeatures'}->{$vf2}->start} = $vf2;
	    if (($ld_container->{'ldContainer'}->{$ld_key}->{$sample_id}->{'r2'} > $r2) and ($sample_id == $population_id)){
		#there is high LD between these 2 variations in this population
		push @{$variation_features->{$ld_container->{'variationFeatures'}->{$vf1}->start}}, $ld_container->{'variationFeatures'}->{$vf2}->start;
		push @{$variation_features->{$ld_container->{'variationFeatures'}->{$vf2}->start}}, $ld_container->{'variationFeatures'}->{$vf1}->start;
	    }
	}
    }
    return $variation_features;
}
