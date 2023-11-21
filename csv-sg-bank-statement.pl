#!/usr/bin/perl
use strict;
use warnings;
use English;
use List::Util qw(min max);
use utf8; # ut8 in code

use open OUT =>":encoding(utf8)";

# Debugging
#use Data::Dumper;
#$" = "#"; # joining array during interpolation


###### REs and Params ######

# at least 3 spaces followed by XX/XX/2 pattern
my $statementDatesRE = '
	du
	\s+ (\d{2}\/\d{2}\/\d{4}) \s+
	au
	\s+ (\d{2}\/\d{2}\/\d{4})
';
my $startingBalanceRE = '
	solde \s+
	pr[éÉe]c[éÉe]dent .*  # case is not managed well for latin1 caracters
	\d{2}\/\d{2}\/\d{4} \D* # date followed by any non digit caracter
	([\d\.,]+)  # amount
';
my $endingBalanceRE = '
	nouveau \s+ solde .*
	\d{2}\/\d{2}\/\d{4} \D*  # date followed by any non digit caracter
	([\d\.,]+)  # amount
';
my $dateSpacingRE = ' {3,}(?=\d{2}\/\d{2}\/2)';
# at least 3 spaces followed by 1.000,20 format (matches 1,XX or 0,XX as well)
	# not followed by any letter (end of line)
my $numberSpacingRE = ' {3,}(?=(?:0?[1-9]*\d+)[,\.]+\d{2,})(?!\s*[[:alpha:]]+)';
# at least 2 spaces immediately preceded by a foramted date
#	 and followed by visible caracter
my $labelSpacingRE = '(?<=\d{2}\/\d{2}\/2\d{3})\s{2,}(?=[[:graph:]]+)';
my $moveLineRE = '^\d{2}\/';
my $debitRE  = '\bEMIS\b';
my $creditRE  = '\bRECU\b';
my $headerRE = '^\s*\b[dD]ate\b';
my $blacklistRE = '(Duplicata|\*)'; # grouping matters

# Fallback partner’s name detection
# my $partnerMoveRE = 'VIR.+POUR:\s+([[:alnum:]\. ]+)(?=\-)'; # trimming needed

my $accountNumber = "512001";
my %partners = (
	# mapping lower-cased label content to ERP partner names
	# examples
	"google" => "Google",
	"ovh" => "OVH",
	"soyoustart" => "OVH",
	"mailchimp" => "Mailchimp",
	"aws" => "Amazon Web Services EMEA SARL",
	"elastic" => "Elasticsearch AS",
  "netlify" => "Netlify",
	"circleci.com" => "CircleCI"
);

$ORS = "\n"; # Output Record Seperator aka $\
$OFS = ";"; # Output Field Separator aka $,

##### Handling files sequentially ######

my $pdffile = "";
my $csvfile = "";
my $nbFiles = 0;
my ($startingBalance, $endingBalance);
my ($statementStartDate, $statementEndDate);

while (<>) {
    if ($pdffile ne $ARGV) {
		$pdffile = $ARGV;
		$csvfile = $pdffile =~ s|(20\d{4,6}).*\.pdf|ReleveCSV_512001_$1.csv|r;

		open my $textStmt, "bash bankpdf2text $pdffile|"
			or die "Impossible to read from pdf2text pipe: $!\n";
		open my $CSVStmt, ">", $csvfile
			or die "Can't write csv: $!\n";

		($startingBalance, $endingBalance) = (0, 0);
		($statementStartDate, $statementEndDate) = ("", "");
		
		convertFile($textStmt, $CSVStmt, $pdffile);
		$nbFiles++;
	}
}

print "Processed $nbFiles statement file(s). Have nice accounting !\n";

###### Parsing ######

sub convertFile {
	my ($textStmt, $CSVStmt, $pdffile) = @_;

	my (%moves, @headerLine, $labelIndex, $amountIndex, $maxAmountIndex, $minAmountIndex);
	my ($moveNr, $totalDebit, $totalCredit, $totalDebitCtrl, $totalCreditCtrl, $realign) = (0) x 6;

	select $CSVStmt;

	while (<$textStmt>) {
		s|$blacklistRE|" " x (length $1)|ige; # replace characters by as many spaces
		if (/$statementDatesRE/ix && ! $statementEndDate) {
			($statementStartDate, $statementEndDate) = ($1, $2);
		} elsif (/$startingBalanceRE/ix && ! $startingBalance) {
			$startingBalance = getFormattedFloat($1);
		} elsif (/$endingBalanceRE/ix && ! $endingBalance) {
			$endingBalance = getFormattedFloat($1);
			last;
		} elsif (/$headerRE/) {
			chomp;
			@headerLine = @headerLine || split /\s{3,}/;

			matchPageAmounts(\%moves, $minAmountIndex, $maxAmountIndex);

			# recompute alignement on each page
			$realign = 1;
			$minAmountIndex = 0;
			$maxAmountIndex = 0;
		} elsif (/$moveLineRE/ && ++$moveNr) {
			my @fields = split /$dateSpacingRE|$numberSpacingRE|$labelSpacingRE/;
			my $amount = $fields[3] =~ s|[\*\.\s]+||rg;

			#$labelIndex = index($_, $fields[2]) + 1; # same on for all moves on given page
			$amountIndex = index($_, $fields[3]) + 1;

			#print "$labelIndex, \$#+: $#+, $-[0], $+[0], $&"; # debug

			#$moves{$moveNr}{"line"} = $_;
			$moves{$moveNr}{"date"} = getFormattedDate($fields[0]);
			$moves{$moveNr}{"valueDate"} = getFormattedDate($fields[1]);
			$moves{$moveNr}{"label"} = $fields[2];
			$moves{$moveNr}{"amount"} = $amount;
			$moves{$moveNr}{"statementDate"} = getFormattedDate($statementEndDate);

			$moves{$moveNr}{"labelIndex"} = $labelIndex;
			$moves{$moveNr}{"amountIndex"} = $amountIndex;

			if (! @headerLine && ! $realign) {
				warn "$pdffile: Could not parse date header in bank statement.";
			} elsif ((! $labelIndex || ! $amountIndex) && ! $realign) {
				warn "$pdffile: Could not set label and amount indexes in bank statement.";
			} elsif ($realign) {
				$labelIndex = index($_, $fields[2]) + 1;
				$realign = 0;
			}

			$minAmountIndex = min($minAmountIndex || $amountIndex, $amountIndex);
			$maxAmountIndex = max($maxAmountIndex || $amountIndex, $amountIndex);
		} elsif (/^(\s*).+/ && $moveNr && ($+[1] + 1) == $labelIndex) {
			# Append only extra label lines related to last bank move
			# Filter out bank news or footer content
			unless (/(Haussmann 75009)|(552 120 222 RCS Paris)/) {
				chomp; # removes new line
				$moves{$moveNr}{"label"} = qq{$moves{$moveNr}{"label"} - $_};
			} # Concatenate to last move's label
		} elsif (/TOTAUX/) {
			my @total = split /
				\s+
				(?= \d{1,}[\.,]? # thousands and more
					\d* [\.,]       # hundreds and less
					\d{2,}			# cents
				)
			/x;
			
			$totalDebitCtrl += getFormattedFloat($total[1]);
			$totalCreditCtrl += getFormattedFloat($total[2] || 0);
		}
	}

	###### Checks and Export ######

	print "line_ids/date", "Libelle line_ids/label", 
		"Debit", "Credit", "line_ids/amount",
		"Partner", "line_ids/partner", "line_ids/bank_account_id",
		 # statement variables below
		"Date", "Name", "Balance initiale", "Solde final", "Reference externe";

	matchPageAmounts(\%moves, $minAmountIndex, $maxAmountIndex);

	foreach my $mv (sort { $a <=> $b } keys %moves) {
		my $label = $moves{$mv}{"label"} =~ s| {2,}| |gr; # remove duplicate spaces
		my @date = $pdffile =~ /(\d{6,})/; # YYYYMM expected

		my $debitCreditThresh = $moves{$mv}{"minAmountIndex"} # empirical threshold
			+ 0.6 * ($moves{$mv}{"maxAmountIndex"} - $moves{$mv}{"minAmountIndex"});
		my $isDebit =  (uc $label !~ /$creditRE/)
			&& ((uc $label =~ /$debitRE/)
				|| ($moves{$mv}{"amountIndex"} <= $moves{$mv}{"minAmountIndex"} + 10)
				|| ($moves{$mv}{"amountIndex"} <= $debitCreditThresh));

		my $debit = $isDebit ? $moves{$mv}{"amount"} : 0;
		my $credit = $isDebit ? 0 : $moves{$mv}{"amount"};

		$totalDebit += getFormattedFloat($debit);
		$totalCredit += getFormattedFloat($credit);

		findPartner(\%moves, $mv);

		my @statementAttributes = ("") x 6;
		my $statementName = $pdffile =~ s|.*?\/?([[:alnum:]_]+.pdf)|$1|r;
		if ($mv == 1) {
			@statementAttributes = (
				$moves{$moveNr}{"statementDate"},
				qq("Relevé Société Générale @date"),
				$startingBalance,
				$endingBalance,
				qq("$statementName")
			);
		}

		print qq("$moves{$mv}{'date'}"),
			# qq("$moves{$mv}{'valueDate'}"),
			qq("$label"),
			$credit, # Inverting debit and credit for company accounting
			$debit,
			getFormattedFloat($credit) - getFormattedFloat($debit),
			qq("$moves{$mv}{'partner'}"),
			qq("$moves{$mv}{'partner_name'}"),
			$accountNumber,
			@statementAttributes;
	}
	#print Dumper \%moves; # debug

	my $matchingDebit = ! $totalDebitCtrl || abs($totalDebitCtrl - $totalDebit) < 0.01;
	my $matchingCredit = ! $totalCreditCtrl || abs($totalCreditCtrl - $totalCredit) < 0.01;
	if (! $matchingDebit or ! $matchingCredit) {
		warn "$pdffile: Total debit ($totalDebit) & credit ($totalCredit) do not match content.
	(${totalDebitCtrl}EUR, ${totalCreditCtrl}EUR according to pdf statement, respectively)
	Please check parsing rules";
	}

	closeAndRename($CSVStmt, $totalDebitCtrl, $totalCreditCtrl, $moveNr);
}


###### Utility subroutines ######

sub matchPageAmounts {
	my %moves = %{$_[0]};
	my ($minAmountIndex, $maxAmountIndex) = ($_[1], $_[2]);
	# match debit/credit for lines in last parsed page, depending on alignment
	foreach my $mv (keys %moves) {
		$moves{$mv}{"minAmountIndex"} = $minAmountIndex
			if ! exists($moves{$mv}{"minAmountIndex"});
		$moves{$mv}{"maxAmountIndex"} = $maxAmountIndex
			if ! exists($moves{$mv}{"maxAmountIndex"});
	}
}

sub getFormattedFloat {
	my $amount = $_[0] =~ s|\s||r;
	$amount =~ tr|,.|.|d;
	return $amount;
}

sub getFormattedDate {
	return $_[0] =~ s|(\d{2})\/(\d{2})\/(2\d{3})|$3-$2-$1|r;
}

sub findPartner {
	my %moves = %{$_[0]}; # dereference hash
	my $mv = $_[1];
	$moves{$mv}{"partner"} = "";
	$moves{$mv}{"partner_name"} = "";

	foreach my $part (keys %partners) {
		$moves{$mv}{"partner_name"} = $partners{$part} if (index((lc $moves{$mv}{"label"}), $part) >= 0);
	}
	
	# unless ($moves{$mv}{"partner_name"}) {
	#	my @partnerFallback = $moves{$mv}{"label"} =~ /$partnerMoveRE/;
	#		if ($partnerFallback[0]) {
	#			$partnerFallback[0] =~ s|\s+$||;
	#			$moves{$mv}{"partner_name"} = $partnerFallback[0];
	#		}
	#}
}

sub closeAndRename {
	my ($CSVStmt, $totalDebitCtrl, $totalCreditCtrl, $moveNr) = @_;

	close($CSVStmt)
		|| die "Could not close bank statement csv file before renaming: $!";

	# CSV file name depends on content
	#rename($csvfile, "TestPearl.csv");
	tr|.|_| for ($totalDebitCtrl, $totalCreditCtrl);
	rename($csvfile,
		$csvfile =~ s|(.*)\.csv|"$1_TOT_D${totalDebitCtrl}_C${totalCreditCtrl}.csv"|re);

	select STDOUT;

	if (! $statementStartDate) {
		print "$pdffile: Could not parse statement end date.\n";
	}
	if (! $startingBalance || ! $endingBalance ) {
		print "$pdffile: starting or ending balance not found.\n";
	} 

	print "$pdffile ==> $csvfile done ($moveNr lines).\n";
}
