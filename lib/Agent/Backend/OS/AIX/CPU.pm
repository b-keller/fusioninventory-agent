package Ocsinventory::Agent::Backend::OS::AIX::CPU;
use strict;

sub check { -r "export LANG=C;lsdev -Cc processor -F name" };

sub run {
  my $params = shift;
  my $inventory = $params->{inventory};
  
  # TODO Need to be able to register different CPU speed!
  
  my $processort;
  my $processorn;
  my $processors; 
  my @lsdev; 
  my @lsattr;

  #lsdev -Cc processor -F name
  #lsattr -EOl proc16
  @lsdev=`export LANG=C;lsdev -Cc processor -F name`;
  for (@lsdev){
    chomp($_);
	@lsattr=`export LANG=C;lsattr -EOl $_ -a 'state:type:frequency'`;
	for (@lsattr){
	   if ( ! /^#/){
	     /(.+):(.+):(.+)/;
	     $processorn ++;
	     $processort=$2;
	     if ( ($3 % 1000000) >= 50000){
		   $processors=int (($3/1000000) +1); 
		 }
		 else {
		  $processors=int (($3/1000000)); 
		 }
	   }
	}
  }

  
  $inventory->setHardware({

      PROCESSORT => $processort,
      PROCESSORN => $processorn,
      PROCESSORS => $processors

    });

}

1
