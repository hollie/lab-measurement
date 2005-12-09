#!/usr/bin/perl -w

#$Id$

package Lab::Data::Writer;

use strict;
use Carp;
use Data::Dumper;
use File::Basename;
use File::Copy;
use Lab::Data::Meta;

my $default_config = {
    output_data_ext     => "DATA",
    output_meta_ext     => "META",

    output_col_sep      => "\t",
    output_line_sep     => "\n",
    output_block_sep    => "\n",
    output_comment_char => "# ",
};

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self  = {};
    bless ($self, $class);
    
    $self->configure(shift);

    return $self;
}

sub configure {
    my $self=shift;
    my $config=shift;

    if (defined($config) && !(ref $config)) {
        return $self->{Config}->{$config};
    }   
    for my $conf_name (keys %{$default_config}) {
        unless ((defined($self->{Config}->{$conf_name})) || (defined($config->{$conf_name}))) {
            $self->{Config}->{$conf_name}=$default_config->{$conf_name};
        } elsif (defined($self->{config}->{$conf_name})) {
            $self->{Config}->{$conf_name}=$config->{$conf_name};
        }
    }
}

sub log_line {
	my ($self,$fh,@data)=@_;
    print $fh (join $self->configure('output_col_sep'),@data),$self->configure('output_line_sep');
}

sub log_finish_block {
    my ($self,$fh)=@_;
    print $fh $self->configure('output_block_sep');
}

sub import_gpplus {
    my $self=shift;
    my %opts=@_;
    my $filename=$opts{filename};
    my $given_name=$opts{newname};
            # archive

    unless ((defined $filename) && ($filename ne '')) {
        warn "What should I import?";
        return ();
    }
    my ($filenamebase,$path,$suffix)=fileparse($filename,qr/_\d+\.TSK/);
    for ($path,$filenamebase) {
        s/\\/\//g;
        s/ /\\ /g;
    }
    my $basename=$path.$filenamebase;
    my $newname=$given_name || $filenamebase;
    my $newpath=$path.$newname."/";
    print "basename: $basename\nnewpath: $newpath\nnewname: $newname\n";
    my @files=sort {
        ($a =~ /$basename\_(\d+)\.TSK/)[0] <=> ($b =~ /$basename\_(\d+)\.TSK/)[0]
    } glob($basename."_*.TSK");

    #print "Files:\n ",(join "\n ",@files),"\n";
    if (-d $newpath) {warn "Destination directory $newpath already exists";return ()}
    unless (mkdir $newpath) {
        warn "Cannot create directory $newpath: $!\n";
        return ();
    }
    my $meta=new Lab::Data::Meta({
        data_complete           => 0,
        dataset_title           => $newname,
        dataset_description     => 'Imported by Importer.pm on '.(join "-",localtime(time)),
        data_file               => "$newname.".$self->configure('output_data_ext'),
    });
    $meta->save("$newpath$newname.".$self->configure('output_meta_ext'));
    
    open my $dataout,">$newpath$newname.".$self->configure('output_data_ext');
    
    my (@min,@max);
    my $blocknum=0;
    my $linenum=0;
    my $total_lines=0;
    my $numcol;
    my $ok=0;
    
    for my $old_file (@files) {
        if (open IN,"<$old_file") {
            while (<IN>) {
                $_=~s/[\n\r]+$//;
                if (/^([\d\-+\.Ee]+;)+/) {
                    if (/E+37/) { warn "Attention: Contains bad data due to overload!\n" }
                    my @value=split ";";
                    $self->log_line($dataout,@value);
                    for (0..$#value) {
                        $min[$_]=$value[$_] if (!(defined $min[$_]) || ($value[$_] < $min[$_]));
                        $max[$_]=$value[$_] if (!(defined $max[$_]) || ($value[$_] > $max[$_]));
                    }
                    if (($linenum==0) && ($blocknum==0)) {
                        $numcol=$#value;
                        for (0..$numcol) {
                            $meta->column_label($_,'column '.($_+1));
                        }
                    } elsif ($numcol!=$#value) {
                        die "spaltenzahl scheisse in zeile $linenum von block $blocknum.\n".
                            "sollte ".1+$numcol." sein. so habe ich keinen bock und sterbe jetzt";
                    }
                    $linenum++;$total_lines++;
                } elsif (/^Saved at ([\d:]{8}) on ([\d.]{8})/) {
                    #Zeit und Datum werden von GPplus pro File/Block gespeichert
                    my ($time,$date)=($1,$2);
                    $meta->block_comment($blocknum,"Saved at $time on $date");
                    $meta->block_timestamp($blocknum,"$date-$time");
                    $meta->block_original_filename($blocknum,$old_file);
                } elsif ($blocknum == 0) {
                    #Kommentar
                    $meta->dataset_description($meta->dataset_description().$_."\n")
                        if ($_ !~ /DATA MEASURED/);
                } else {
                    #ignorierter Kommentar: GPplus schreibt gleichen Kommentar in jedes File
                }
            }
            close IN;
            $blocknum++;
            $self->log_finish_line($dataout);
            if ($linenum > 0) { $ok=1 }
            $linenum=0;
        } else {
            warn "Cannot open file $old_file: $!\n";
            return ();
        }
    }
    close $dataout;
    
    unless ($ok) {
        warn "No data!\n";
        return ();
    }
    chmod 0440,"$newpath$newname.".($self->configure('output_data_ext'))
        or warn "Cannot change permissions for newly created data file: $!\n";
    for (0..$#min) {
        $meta->column_min($_,$min[$_]);
        $meta->column_max($_,$max[$_]);
    }
    $meta->data_complete(1);
    $meta->save("$newpath$newname.".$self->configure('output_meta_ext'));
    if ($opts{archive}) {
        if (-d $newpath."imported_gpplus") {warn "Destination directory {$newpath}imported_gpplus already exists";return ()}
        unless (mkdir $newpath."imported_gpplus") {
            warn "Cannot create directory {$newpath}imported_gpplus: $!\n";
            return ();
        };
        for my $old (@files) {
            my ($oldname,$oldpath,$oldsuffix)=fileparse($old,qr/\..*/);
            if ($opts{archive} eq 'move') {
                move $old,$newpath."imported_gpplus/".$oldname.$oldsuffix or warn "Cannot move file $old to archive: $!\n";
            } else {
                copy $old,$newpath."imported_gpplus/".$oldname.$oldsuffix or warn "Cannot copy file $old to archive: $!\n";
            }
            chmod 0440,$newpath."imported_gpplus/".$oldname.$oldsuffix or warn "Cannot change permissions: $!\n";
        }
    }
    return ($newpath,$newname,$#files,$total_lines,$numcol+1,$blocknum-1);
}

1;

__END__

=head1 NAME

Lab::Data::Writer - A dataset import tool

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 CONSTRUCTOR

=head1 METHODS

=head2 configure

    output_data_ext     => "DATA",
    output_meta_ext     => "META",

    output_col_sep      => "\t",
    output_line_sep     => "\n",
    output_block_sep    => "\n",
    output_comment_char => "# ",

=head2 import_gpplus(%opts)

Imports GPplus TSK-files. Valid parameters are

  filename => 'path/to/one/of/the/tsk-files',
  newname  => 'path/to/new/directory/newname',
  archive  => '[copy|move]'

The path C<path/to/new/directory/> must exist, while C<newname> shall not
exist there.

=head1 AUTHOR/COPYRIGHT

This is $Id$

Copyright 2004 Daniel Schr�er (L<http://www.danielschroeer.de>)

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut

# generalized data loader br�uchte
# regex
# der blockseparator matcht (z.B. Leerzeile)
#   oder Sonderfall FILES (wobei er einfach alle filenames f�r FILE in liste bekommt)
#  der Datenzeile matcht und in $1, $2 etc. teilt; gar nicht so einfach
#  der Kommentarzeile matcht

