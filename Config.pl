#!/usr/bin/perl -i
use strict;
our @Arguments       = @ARGV;
our $Code            = "BATL";
our $MakefileDefOrig = 'src/Makefile.def';

my $config     = "share/Scripts/Config.pl";

my $GITCLONE = "git clone"; my $GITDIR = "herot:/GIT/FRAMEWORK/";

if (-f $config or -f "../../$config"){
}else{
    `$GITCLONE $GITDIR/share.git; $GITCLONE $GITDIR/util.git`;
}

if (-d "src"){
}else{
    `$GITCLONE $GITDIR/srcBATL.git src`;
}



require "share/Scripts/Config.pl";

# Variables inherited from share/Scripts/Config.pl
our $ERROR;
our $WARNING;
our $Help;
our $Show;
our $ShowGridSize;
our $NewGridSize;
our $AmrRatio;
our $NewAmrRatio;
our $NewGhostCell;

our %Remaining; # Unprocessed arguments


# Source code directory
my $Src         = 'src';

# Grid size variables
my $NameGridFile = "$Src/BATL_size.f90";
my $GridSize;
my ($nI, $nJ, $nK, $iRatio, $jRatio, $kRatio);
my $GhostCell;
my $Force;

&print_help if $Help;

# Read previous grid size
&get_settings;

foreach (@Arguments){
    if(/^-r=(.*)$/)     {$NewAmrRatio=$1;  next};
    if(/^-ng=(.*)$/)    {$NewGhostCell=$1; next};
    if(/^-f$/)          {$Force=1;         next};
    warn "WARNING: Unknown flag $_\n" if $Remaining{$_};
}

# Set new grid size and AMR dimensions
&set_grid_size if ($NewGridSize and $NewGridSize ne $GridSize)
    or            ($NewAmrRatio and $NewAmrRatio ne $AmrRatio)
    or   (length($NewGhostCell) and $NewGhostCell ne $GhostCell);

# Show grid size and AMR dimensions
if($ShowGridSize or $Show){
    print "Config.pl -g=$nI,$nJ,$nK -r=$iRatio,$jRatio,$kRatio -ng=$GhostCell\n";
}

exit;

#############################################################################

sub get_settings{

    # Read size of the grid from $NameGridFile
    open(MODSIZE,$NameGridFile) or die "$ERROR could not open $NameGridFile\n";
    while(<MODSIZE>){
        next if /^\s*!/; # skip commented out lines
        $nI=$1           if /\bnI\s*=\s*(\d+)/i;
        $nJ=$1           if /\bnJ\s*=\s*(\d+)/i;
        $nK=$1           if /\bnK\s*=\s*(\d+)/i;
	$iRatio=$1       if /\biRatio\s*=\s*min\(\s*(\d)/;
	$jRatio=$1       if /\bjRatio\s*=\s*min\(\s*(\d)/;
	$kRatio=$1       if /\bkRatio\s*=\s*min\(\s*(\d)/;
	$GhostCell=$1    if /\bnG\s*=\s*(\d)/;
    }
    close MODSIZE;

    die "$ERROR could not read nI from $NameGridFile\n" unless length($nI);
    die "$ERROR could not read nJ from $NameGridFile\n" unless length($nJ);
    die "$ERROR could not read nK from $NameGridFile\n" unless length($nK);

    die "$ERROR could not read iRatio from $NameGridFile\n" 
	unless length($iRatio);
    die "$ERROR could not read jRatio from $NameGridFile\n" 
	unless length($jRatio);
    die "$ERROR could not read kRatio from $NameGridFile\n" 
	unless length($kRatio);

    die "$ERROR could not read nG from $NameGridFile\n" 
	unless length($GhostCell);

    $GridSize  = "$nI,$nJ,$nK";
    $AmrRatio  = "$iRatio,$jRatio,$kRatio";
}

#############################################################################

sub set_grid_size{

    $GridSize = $NewGridSize if $NewGridSize;

    if($GridSize =~ /^[1-9]\d*,[1-9]\d*,[1-9]\d*$/){
	($nI,$nJ,$nK) = split(',', $GridSize);
    }elsif($GridSize){
	die "$ERROR ".
	    "-g=$GridSize should be 3 positive integers separated by commas\n";
    }

    $AmrRatio = $NewAmrRatio if $NewAmrRatio;

    if($AmrRatio =~ /^[12],[12],[12]$/){
	($iRatio,$jRatio,$kRatio) = split(',', $AmrRatio);
    }elsif($GridSize){
	die "$ERROR ".
	    "-r=$AmrRatio should be 3 integers = 1 or 2 separated by commas\n";
    }

    $GhostCell = $NewGhostCell if length($NewGhostCell);

    # Check the grid size (to be set)
    if(not $Force){
	die "$ERROR nK=$nK must be 1 if nJ is 1\n" 
	    if $nJ == 1 and $nK > 1;
	die "$ERROR nI=$nI must be an even integer >= 4 if iRatio=2\n" 
	    if $iRatio==2 and ($nI<4 or $nI%2!=0);
	die "$ERROR nJ=$nJ must be 1 or an even integer >= 4 if jRatio=2\n" 
	    if $jRatio==2 and ($nJ==2 or $nJ%2!=0) and $nJ>1;
	die "$ERROR nK=$nK must be 1 or an even integer >= 4 if kRatio=2\n" 
	    if $kRatio==2 and ($nK==2 or $nK%2!=0) and $nK>1;

	die "$ERROR -ng=$GhostCell should be 0,1,..,9\n" 
	    if $GhostCell !~ /^\d$/;

	die "$ERROR -ng=$GhostCell should not exceed nI/iRatio=$nI/$iRatio\n"
	    if $GhostCell > $nI/$iRatio;
	die "$ERROR -ng=$GhostCell should not exceed nJ/jRatio=$nJ/$jRatio\n"
	    if $GhostCell > $nJ/$jRatio and $nJ>1;
	die "$ERROR -ng=$GhostCell should not exceed nK/kRatio=$nK/$kRatio\n"
	    if $GhostCell > $nK/$kRatio and $nK>1;
    }

    print "Writing new grid size $GridSize with $GhostCell ghost cell layers". 
	" and AMR ratio $AmrRatio into $NameGridFile...\n";

    @ARGV = ($NameGridFile);

    while(<>){
	if(/^\s*!/){print; next} # Skip commented out lines

	s/\b(nI\s*=[^0-9]*)\d+/$1$nI/i;
	s/\b(nJ\s*=[^0-9]*)\d+/$1$nJ/i;
	s/\b(nK\s*=[^0-9]*)\d+/$1$nK/i;
	s/\b(iRatio\s*=[^0-9]*)\d+/$1$iRatio/i;
	s/\b(jRatio\s*=[^0-9]*)\d+/$1$jRatio/i;
	s/\b(kRatio\s*=[^0-9]*)\d+/$1$kRatio/i;
	s/\b(nG\s*=[^0-9]*)\d/$1$GhostCell/i;
	print;
    }

}

##############################################################################

sub print_help{

    print "
Additional options for BATL/Config.pl:

-f  Force grid settings without checking them. This can be useful for some
    exceptional grids.

-g=NI,NJ,NK
    If -g is used without a value, it shows grid size. 
    Otherwise set grid dimensionality and the grid block size.
    NI, NJ and NK are the number of cells in a block in the I, J and K 
    directions, respectively. If nK=1 the last dimension is ignored: 2D grid.
    If nJ=1 and nK=1 then the last two dimensions are ignored: 1D grid.

-ng=NG
    Set number of ghost cells to NG. Minimum value is 0, maximum value is 3.

-r=IRATIO,JRATIO,KRATIO
    Set the AMR ratio for each (non-ignored) dimensions. The value can be
    1 (for no adaptation), or 2 for adaptation in the given direction.

Examples for BATS/Config.pl:

Show grid size:

    Config.pl -g

Set 3D domain with 3D AMR and block size 8x8x8 cells and 3 ghost cells:

    Config.pl -g=8,8,8 -r=2,2,2 -ng=3

Set block size 40x10x1 cells (2D grid) with AMR in the first dimension only:

    Config.pl -g=40,10,1 -r=2,1,1

Set block size to 64x2x2 and still keep AMR on (useful to read BATSRUS grid):

    Config.pl -f -g=64,2,2 -r=2,2,2

\n";
    exit 0;
}

