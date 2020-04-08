################################################################
#  $Id$
################################################################
#
#  98_readingsWatcher
#
#  (c) 2015,2016 Copyright: HCS,Wzut
#  All rights reserved
#
#  FHEM Forum : https://forum.fhem.de/index.php/topic,49408.0.html
#
#  This code is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#
#  2.1.0  =>  06.04.20
#  2.0.0  =>  05.04.20 perlcritic -4 / PBP
#  1.7.1  =>  25.01.20 fix ErrorValue 0
#  1.7.0  =>  12.01.20 add OR / AND watching
#  1.6.0  =>  27.08.19 package, Meta
#  1.5.0  =>  18.02.19
#  1.3.0  =>  26.01.18 use ReadingsAge
#  1.2.0  =>  15.02.16 add Set, Get
#  1.1.0  =>  14.02.16
#  1.0.0  =>  (c) HCS, first version
#
################################################################

package FHEM::readingsWatcher;  ## no critic 'package'
# das no critic könnte weg wenn die Module nicht mehr zwingend mit NN_ beginnnen müssen

use strict;
use warnings;
use utf8;
use GPUtils qw(GP_Import GP_Export); # wird für den Import der FHEM Funktionen aus der fhem.pl benötigt
use Time::HiRes qw(gettimeofday);
use List::Util qw(uniq);

BEGIN
{
    # Import from main::
    GP_Import(
	qw(
	attr
	AttrVal
	AttrNum
	CommandAttr
	addToAttrList
	delFromAttrList
	delFromDevAttrList
	defs
	devspec2array
	init_done
	InternalTimer
	RemoveInternalTimer
	IsDisabled
	IsIgnored
	Log3
	modules
	readingsSingleUpdate
	readingsBulkUpdate
	readingsBeginUpdate
	readingsDelete
	readingsEndUpdate
	readingFnAttributes
	ReadingsNum
	ReadingsAge
	ReadingsTimestamp
	ReadingsVal
	setReadingsVal
	CommandSetReading
	CommandDeleteReading
	gettimeofday
	TimeNow)
    );

    # Export to main
    GP_Export( qw(Initialize) );
}

my $hasmeta = 0;
# ältere Installationen haben noch kein Meta.pm
if (-e $attr{global}{modpath}.'/FHEM/Meta.pm') {
    $hasmeta = 1;
    require FHEM::Meta;
}


sub Initialize {

    my $hash = shift;
    $hash->{GetFn}     = "FHEM::readingsWatcher::Get";
    $hash->{SetFn}     = "FHEM::readingsWatcher::Set";
    $hash->{DefFn}     = "FHEM::readingsWatcher::Define";
    $hash->{UndefFn}   = "FHEM::readingsWatcher::Undefine";
    $hash->{AttrFn}    = "FHEM::readingsWatcher::Attr";
    $hash->{AttrList}  = "disable:0,1 interval deleteUnusedReadings:1,0 readingActivity ".$readingFnAttributes;

    return  FHEM::Meta::InitMod( __FILE__, $hash ) if ($hasmeta);

    return;
}

##################################################################################### 

sub Define {

    my $hash = shift;
    my $def  = shift;
    my ($name, $type, $noglobal) = split(m{ \s+ }xms, $def, 3);

    if (exists($modules{readingsWatcher}{defptr})) {
	my $error = 'one readingsWatcher device is already defined !';
	Log3 $hash, 1, $error;
	return $error;
    }

    $modules{readingsWatcher}{defptr} = $hash;

    if (defined($noglobal) && ($noglobal  eq 'noglobal')) {
	$hash->{DEF} = 'noglobal';
    }
    else {
	addToAttrList('readingsWatcher');
	$hash->{DEF} = 'global'; # global -> userattr
    }

    CommandAttr(undef, "$name interval 60")          unless (exists($attr{$name}{interval}));
    CommandAttr(undef, "$name readingActivity none") unless (exists($attr{$name}{readingActivity}));

    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+5, 'FHEM::readingsWatcher::OnTimer', $hash, 0);

    if ($hasmeta) {
	return $@ unless ( FHEM::Meta::SetInternals($hash) )
    }

  return;
}

#####################################################################################

sub Undefine {

    my $hash = shift;
    RemoveInternalTimer($hash);
    delete($modules{readingsWatcher}{defptr});

    if ($hash->{DEF} eq 'global') { # werden die meisten haben 

	delFromAttrList('readingsWatcher'); # global -> userattr
	# wer hat alles ein Attribut readingsWatcher gesetzt ?
	foreach (devspec2array("readingsWatcher!=")) {
	    delFromDevAttrList($_, 'readingsWatcher');  # aufräumen
	}
    }
 
    return;
}

#####################################################################################

sub Set {

    my $hash = shift;
    my $name = shift;
    my $cmd  = shift // return "set $name needs at least one argument !";

    if ($cmd eq 'inactive') {
	readingsSingleUpdate($hash, 'state', 'inactive', 1);
	RemoveInternalTimer($hash);
	$hash->{INTERVAL} = 0;
	return;
    }

    if ($cmd eq 'active') {
	readingsSingleUpdate($hash, 'state', 'active', 1);
	$hash->{INTERVAL} = AttrVal($name,'interval',60);
	return;
    }

    return  if (IsDisabled($name));

    if (($cmd eq 'checkNow') || ($cmd eq 'active')) {
	OnTimer($hash);
	return;
    }

    if  ($cmd eq 'clearReadings') {

	foreach (keys %{$defs{$name}{READINGS}}) { # alle eigenen Readings
	    if ($_ =~ /_/) { # device_reading
		readingsDelete($hash, $_);
		Log3 $hash,4,"$name, delete reading ".$_;
	    }
	}

    return;
    }

    return "unknown argument $cmd, choose one of checkNow:noArg inactive:noArg active:noArg clearReadings:noArg";
}

#####################################################################################

sub Get {

    my $hash = shift;
    my $name = shift;
    my $cmd  = shift // return "get $name needs at least one argument !";

    return getStateList($name) if ($cmd eq 'devices');

    return "unknown command $cmd, choose one of devices:noArg";
}

#####################################################################################

sub getStateList {

    my $name = shift;

    my @devs;

    foreach my $device (devspec2array("readingsWatcher!=")) {
	my $rSA  = ($device ne  $name) ? AttrVal($device, 'readingsWatcher', '') : '';

	next if (!$rSA);

	if (IsDisabled($device)) {
	    push @devs, "$device,-,-,disabled,-";
	}
	elsif (IsIgnored($device)) {
	    push @devs, "$device,-,-,ignored,-";
	}
	else { # valid device
	    push @devs , IsValidDevice($device,$rSA);
	}
    }

    return formatStateList(@devs);
}

#####################################################################################

sub IsValidDevice {

    my $device = shift;
    my @devs;

    foreach (split(';', shift)) { # Anzahl Regelsätze pro Device, meist nur einer

	$_ =~ s/\+/,/g; # OR Readings wie normale Readingsliste behandeln
	$_ =~ s/ //g;

	my ($timeout,undef,@readings) = split(',', $_); # der ggf. vorhandene Ersatzstring wird hier nicht benötigt

	if (!@readings) {
	    push @devs, "$device,-,-,wrong parameters,-";
	}
	else {
	    foreach my $reading (@readings) { # alle zu überwachenden Readings

		my ($age,$state);

		$reading =~ s/ //g;

		if (($reading eq 'state') && (ReadingsVal($device, 'state', '') eq 'inactive')) {

		    $state   = 'inactive';
		    $age     = '-';
		}
		else {
		    $age = ReadingsAge($device, $reading, undef);

		    if (!defined($age)) {
			$state   = 'unknown';
			$age     = 'undef';
		    }
		    else {
			$state = (int($age) > int($timeout)) ? 'timeout' : 'ok';
		    }
		}
		push @devs, "$device,$reading,$timeout,$state,$age";
	    }
	}
    }

    return @devs;
}

#####################################################################################

sub formatStateList {

    # Device | Reading    | Timeout |   State |     Age
    # -------+------------+---------+---------+--------
    # CUL    | credit10ms |     300 |      ok |      56
    # lamp   | state      |     900 | timeout | 3799924
    # -------+------------+---------+---------+--------

    my (@devs) = @_;
    return 'Sorry, no devices with valid attribute readingsWatcher found !' if (!@devs);

    my ($dw,$rw,$tw,$sw,$aw) = (6,7,7,5,3); # Startbreiten, bzw. Mindestbreite durch Überschrift

    foreach (@devs) {
	my ($d,$r,$t,$s,$g)  = split(',', $_);
	# die tatsächlichen Breiten aus den vorhandenen Werten ermitteln
	$dw = length($d) if (length($d) > $dw);
	$rw = length($r) if (length($r) > $rw);
	$tw = length($t) if (length($t) > $tw);
	$sw = length($s) if (length($s) > $sw);
	$aw = length($g) if (length($g) > $aw);
    }

    my $head  = 'Device '  .(' ' x ($dw-6))
              .'| Reading '.(' ' x ($rw-7)).'| '
              .(' ' x ($tw-7)).'Timeout | '
              .(' ' x ($sw-5)).'State | '
              .(' ' x ($aw-3)).'Age';

    my $separator = ('-' x length($head));

    while ( $head =~ m/\|/g ) { # alle | Positionen durch + ersetzen
	substr $separator, (pos($head)-1), 1, '+';
    }

    $head .= "\n".$separator."\n";

    my $s;
    foreach (@devs) {
	my ($d,$r,$t,$e,$g)  = split(',', $_);

	$s .= $d . (' ' x ($dw - length($d))).' ';       # left-align Device
	$s .= '| '. $r . (' ' x ($rw - length($r))).' '; # left-align Reading
	$s .= '| ' . (' ' x ($tw - length($t))).$t.' ';  # Timeout right-align
	$s .= '| ' . (' ' x ($sw - length($e))).$e.' ';  # State   right-align
	$s .= '| ' . (' ' x ($aw - length($g))).$g;      # Age     right-align
	$s .= "\n";
    }

    return $head.$s.$separator;
}

#####################################################################################

sub Attr {

    my ($cmd, $name, $attrName, $attrVal) = @_;

    return 'attribute not allowed for self !' if ($attrName eq 'readingsWatcher');

    my $hash = $defs{$name};

    if ($cmd eq 'set')
    {
	if ($attrName eq 'disable') {
	    readingsSingleUpdate($hash, 'state', 'disabled', 1) if (int($attrVal) == 1);
	    OnTimer($hash) if (int($attrVal) == 0);
	    return;
	}

	if (($attrName eq 'readingActivity') && ($attrVal eq 'state')) {
	    my $error = 'forbidden value state !';
	    Log3 $hash,1,"$name, readingActivity $error";
	    return $error;
	}
    }

    if (($cmd eq 'del') && ($attrName eq 'disable')) {
	    OnTimer($hash);
    }

    return;
}

#####################################################################################

sub OnTimer {

    my $hash     = shift;
    my $name     = $hash->{NAME};
    my $interval = AttrNum($name, 'interval', 0);

    $hash->{INTERVAL} = $interval;
    RemoveInternalTimer($hash);

    return if (!$interval);

    InternalTimer(gettimeofday() + $interval, 'FHEM::readingsWatcher::OnTimer', $hash, 0);

    readingsSingleUpdate($hash, 'state', 'disabled', 0) if (IsDisabled($name));
    return if ( IsDisabled($name) || !$init_done );

    my ($readingsList , @devices);
    my ($alive_count , $readings_count)  = (0, 0);
    my @toDevs   = ();
    my @deadDevs = ();
    my @skipDevs = ();
    my ($readingActifity,$dead,$alive) = split(':', AttrVal($name, 'readingActivity', 'none:dead:alive'));

    $dead  //= 'dead';  # if (!defined($dead));
    $alive //= 'alive'; # if (!defined($alive));
    $readingActifity = ''  if ($readingActifity eq 'none');

    foreach (keys %{$defs{$name}{READINGS}}) { # alle eigenen Readings
	$readingsList .=  $_ .',' if ( $_ =~ /_/ );  # nur die Readings mit _ im Namen (Device_Reading)
    }

    readingsBeginUpdate($hash);

    foreach  my $device (devspec2array('readingsWatcher!=')) {

	my $or_and       = 0; # Readings als OR auswerten
	my ($d_a, $d_d)  = (0,0); # Device_alives , Device_deads
	my $timeOutState = '';

	my $rSA = ($device eq  $name) ? '' : AttrVal($device, 'readingsWatcher', '');

	next if (!$rSA || IsDisabled($device) || IsIgnored($device));

	push @devices, $device;  # if  !grep {/$device/} @devices;  keine doppelten Namen

	$or_and = 1 if (index($rSA,'+') != -1); # Readings als AND auswerten
	$rSA =~ s/\+/,/g ; # eventuell vorhandene + auch in Komma wandeln

	# rSA: timeout, errorValue, reading1, reading2, reading3, ...
	#      120,---,temperature,humidity,battery
	# or   900,,current,eState / no errorValue = do not change reading

	my $ok_device = 0;

	foreach (split(';', $rSA)) {

	    my ($timeout, $errorValue, @readings_ar) = split(',',  $_);

	    if (@readings_ar) {
		$ok_device  = 1;
		$timeout    = int($timeout);
	    }

	    foreach my $reading (@readings_ar) { # alle zu überwachenden Readings

		$reading =~ s/ //g;
		my $state = 0;

		if ($reading eq 'STATE') { # Sonderfall STATE

		    $reading = 'state';
		    $state   = 1;
		}

		my $age = ReadingsAge($device, $reading, undef);

		if (defined($age)) {

		    $readings_count++;

		    if (($age > $timeout) && ($timeout > 0)) {

			push @toDevs, $device; # if (!grep {/$device/} @toDevs);
			$timeOutState = 'timeout';
			$d_d++; # Device Tote
			my $rts = ReadingsTimestamp($device, $reading, 0);
			setReadingsVal($defs{$device}, $reading, $errorValue, $rts) if ($rts && ($errorValue ne '')); # leise setzen ohne Event
			$defs{$device}->{STATE} = $errorValue if ($state && ($errorValue ne ''));
		    }
		    else {
			$d_a++; # Device Lebende
			$timeOutState = 'ok';
		    }

		    my $d_r = $device.'_'.$reading;

		    readingsBulkUpdate($hash, $d_r, $timeOutState) if ($timeout > 0);
		    $readingsList =~ s/$d_r,// if ($readingsList); # das Reading aus der Liste streichen, leer solange noch kein Device das Attr hat !

		    Log3 $hash,2,"name, invalid timeout value $timeout for reading $device $reading" if ($timeout < 1);
		}
		else {
		    setReadingsVal($defs{$device},$reading,'unknown',TimeNow()) if ($errorValue); # leise setzen ohne Event
		    $defs{$device}->{STATE} = 'unknown' if ($errorValue && $state);
		    Log3 $hash,3,"$name, reading Timestamp for $reading not found on device $device";
		    readingsBulkUpdate($hash, $device.'_'.$reading, 'no Timestamp');
		}
	    }
	} # Anzahl Readings Sätze im Device

	if ($ok_device && $timeOutState) {
	    my $error;

	    if ((!$or_and && $d_d) || ($or_and && !$d_a)) { # tot bei OR und mindestens einem Toten ||  AND aber kein noch Lebender
		$error = CommandSetReading(undef, "$device $readingActifity $dead") if ($readingActifity);
		push @deadDevs, $device; # dead devices
	    }
	    else  { # wenn es nicht tot ist müsste es eigentlich noch leben ....
		$error = CommandSetReading(undef, "$device $readingActifity $alive") if ($readingActifity);
		$alive_count ++; # alive devices
	    }
	    Log3 $hash,2,"$name, $error" if ($error);
	}
	else {
	    Log3 $hash,2,"$name, insufficient parameters for device $device - skipped !";
	    CommandSetReading(undef, "$device $readingActifity unknown") if ($readingActifity);
	    push @skipDevs, $device;
	}
    } # foreach device

    # eventuell doppelte Einträge aus allen vier Listen entfernen
    @devices  = List::Util::uniq @devices  if (@devices);
    @toDevs   = List::Util::uniq @toDevs   if (@toDevs);
    @skipDevs = List::Util::uniq @skipDevs if (@skipDevs);
    @deadDevs = List::Util::uniq @deadDevs if (@deadDevs);

    readingsBulkUpdate($hash, 'readings' , $readings_count);
    readingsBulkUpdate($hash, 'devices'  , int(@devices));
    readingsBulkUpdate($hash, 'alive'    , $alive_count);
    readingsBulkUpdate($hash, 'dead'     , int(@deadDevs));
    readingsBulkUpdate($hash, 'skipped'  , int(@skipDevs));
    readingsBulkUpdate($hash, 'timeouts' , int(@toDevs));
    readingsBulkUpdate($hash, 'state'    , (@toDevs) ? 'timeout' : 'ok');

    # jetzt nicht aktualisierte Readings markieren oder gleich ganz löschen
    # Vorwahl via Attribut deleteUnusedReadings
    clearReadings($name,$readingsList) if ($readingsList);

    (@devices)  ? readingsBulkUpdate($hash, '.associatedWith' , join(',', @devices))  : readingsDelete($hash,        '.associatedWith');
    (@toDevs)   ? readingsBulkUpdate($hash, 'timeoutDevs',      join(',', @toDevs))   : readingsBulkUpdate($hash, 'toDevs',     'none');
    (@deadDevs) ? readingsBulkUpdate($hash, 'deadDevs',         join(',', @deadDevs)) : readingsBulkUpdate($hash, 'deadDevs',   'none');
    (@skipDevs) ? readingsBulkUpdate($hash, 'skippedDevs',      join(',', @skipDevs)) : readingsBulkUpdate($hash, 'skippedDevs','none');

    readingsEndUpdate($hash, 1);

    return;
}

#####################################################################################

sub clearReadings {

    my $name  = shift;
    my $hash  = $defs{$name};

    foreach my $reading (split(',', shift)) # Liste der aktiven Readings
    {
	next if (!$reading);

	if (AttrNum($name, 'deleteUnusedReadings', 1))
	{
	    readingsDelete($hash, $reading);
	    Log3 $hash, 3, "$name, delete unused reading $reading";
	}
	else
	{
	    readingsBulkUpdate($hash, $reading, 'unused');
	    Log3 $hash, 4, "$name, unused reading $reading";
	}
    }

    return;
}

#####################################################################################

1;

=pod
=encoding utf8

=item helper
=item summary    cyclical watching of readings updates
=item summary_DE zyklische Überwachung von Readings auf Aktualisierung
=begin html

<a name="readingsWatcher"></a>
<h3>readingsWatcher</h3>
<ul>
   The module monitors readings in other modules that its readings or their times change at certain intervals and<br>
   if necessary, triggers events that can be processed further with other modules (for example, notify, DOIF).<br>
   Forum : <a href="https://forum.fhem.de/index.php/topic,49408.0.html">https://forum.fhem.de/index.php/topic,49408.0.html</a><br><br>
  
   <a name="readingsWatcher_Define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; readingsWatcher</code><br>
    <br>
    Defines a readingsWatcher device.<br><br>
    Afterwards each FHEM device has the new global attribute readingsWatcher<br>
    This attribute must be assigned at all monitored devices as follows:<br>
    Timeout in seconds, new Reading value, Reading1 of the device, Reading2, etc.<br><br>

    Example: A radio thermometer sends its values at regular intervals (eg.5 seconds)<br>
    If these remain off for a time X, the module can overwrite these invalid values with any other new value (Ex. ???)<br>
    The readingsWatcher attribute could be set here as follows:<br><br>
    <code>attr myThermo readingsWatcher 300, ???, temperature</code><br><br>
    or if more than one reading should be monitored<br><br>
    <code>attr myThermo readingsWatcher 300, ???, temperature, humidity</code><br><br>
    If readings are only to be monitored for their update and should <b>not</b> be overwritten<br>
    so the replacement string must be <b>empty</b><br><br>
    Example : <code>attr myThermo readingsWatcher 300,,temperature,humidity</code><br><br>
    other examples :<br>
    <code>attr weather readingsWatcher 300,,temperature+humidity</code> (new)<br>
    <code>attr weather readingsWatcher 300,,temperature,humidity;3600,???,battery</code>
  </ul>
 
  <a name="readingsWatcherSet"></a>
   <b>Set</b>
   <ul>
   <li>active</li>
   <li>inactive</li>
   <li>checkNow</li>
   <li>clearReadings</li>
   </ul>

  <a name="readingsWatcherGet"></a>
   <b>Get</b>
   <ul>
   devices
   </ul>

  <a name="readingsWatcherAttr"></a>
  <b>Attribute</b>
  <ul>
     <br>
     <ul>
       <a name="disable"></a><li><b>disable</b><br>deactivate/activate the device</li><br>
       <a name="interval"></a><li><b>interval &lt;seconds&gt;</b><br>Time interval for continuous check (default 60)</li><br>
       <a name="deleteUnusedReadings"></a><li><b>deleteUnusedReadings</b><br>delete unused readings (default 1)</li><br>
       <a name="readingActifity"></a><li><b>readingActifity</b> (default none)<br>
       Similar to the HomeMatic ActionDetector, the module can set its own reading in the monitored device and save the monitoring status.<br>
       <code>attr &lt;name&gt; readingActifity actifity</code><br>
       Creates the additional reading actifity in the monitored devices and supplies it with the status dead or alive<br>     
       <code>attr &lt;name&gt; readingActifity activ:0:1</code><br>
       Creates the additional reading activ in the monitored devices and supplies it with the status 0 or 1
      </li><br>
     </ul>
  </ul>
  <br> 
</ul>

=end html

=begin html_DE

<a name="readingsWatcher"></a>
<h3>readingsWatcher</h3>
<ul>
  Das Modul überwacht Readings in anderen Modulen darauf das sich dessen Readings bzw. deren Zeiten in bestimmten Abständen
  ändern<br> und löst ggf. Events aus die mit anderen Modulen (z.B. notify,DOIF) weiter verarbeitet werden können.<br>
  Forum : <a href="https://forum.fhem.de/index.php/topic,49408.0.html">https://forum.fhem.de/index.php/topic,49408.0.html</a><br><br>
 
  <a name="readingsWatcher_Define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; readingsWatcher</code><br>
    <br>
    Definiert ein readingsWatcher Device.<br><br>
    Danach besitzt jedes FHEM Device das neue globale Attribut readingsWatcher<br>
    Dieses Attribut ist bei allen zu überwachenden Geräten wie folgt zu belegen :<br>
    <code>attr mydevice timeout,[Ersatz],Readings1,[Readings2][;timeout2,Ersatz2,Reading,Reading]</code>
    Timeout in Sekunden, neuer Reading Wert, Reading1 des Devices, Reading2, usw.<br><br>
    Beispiel : Ein Funk Thermometer sendet in regelmäßigen Abständen ( z.b.5 Sekunden ) seine Werte.<br> 
    Bleiben diese nun für eine bestimmte Zeit aus, so kann das Modul diesen nun nicht mehr aktuellen Werte (oder Werte)<br>
    mit einem beliebigen anderen Wert überschreiben ( z.B. ??? )<br>
    Das Attribut readingsWatcher könnte hier wie folgt gesetzt werden :<br><br>
    <code>attr AussenTemp readingsWatcher 300,???,temperature</code><br><br>
    oder falls mehr als ein Reading &uuml;berwacht werden soll<br><br>
    <code>attr AussenTemp readingsWatcher 300,???,temperature,humidity</code><br><br>
    Sollen Readings nur auf ihre Aktualiesierung überwacht, deren Wert aber <b>nicht</b> überschrieben werden,<br>
    so  muss der Ersatzsstring <b>leer</b> gelassen werden :<br>
    Bsp : <code>attr AussenTemp readingsWatcher 300,,temperature,humidity</code><br><br>
    <br>
    weitere Beispiele :<br>
    <code>attr wetter readingsWatcher 300,,temperature+humidity</code> (neu)<br>
    <code>attr wetter readingsWatcher 300,,temperature,humidity;3600,???,battery</code>
  </ul>

  <a name="readingsWatcherSet"></a>
   <b>Set</b>
   <ul>
   <li>active</li>
   <li>inactive</li>
   <li>checkNow</li>
   <li>clearReadings</li>
   </ul><br>

  <a name="readingsWatcherGet"></a>
   <b>Get</b>
   <ul>
   <li>devices</li>
   </ul><br>

  <a name="readingsWatcherAttr"></a>
  <b>Attribute</b>
  <ul>
     <br>
     <ul>
       <a name="disable"></a><li><b>disable</b><br>Deaktiviert das Device</li><br>
       <a name="interval"></a><li><b>interval &lt;Sekunden&gt;</b> (default 60)<br>Zeitintervall zur kontinuierlichen Überprüfung</li><br>
       <a name="deleteUnusedReadings"></a><li><b>deleteUnusedReadings</b> (default 1)<br>Readings mit dem Wert unused werden automatisch gelöscht</li><br>
       <a name="readingActifity"></a><li><b>readingActifity</b> (default none)<br>
       Das Modul kann ähnlich dem HomeMatic ActionDetector im überwachten Gerät ein eigenes Reading setzen und den Überwachungsstatus<br>
       in diesem speichern. Beispiel :<br>
       <code>attr &lt;name&gt; readingActifity actifity</code><br>
       Erzeugt in den überwachten Geräten das zusäzliche Reading actifity und versorgt es mit dem Status dead bzw alive<br>     
       <code>attr &lt;name&gt; readingActifity aktiv:0:1</code><br>
       Erzeugt in den überwachten Geräten das zusätzliche Reading aktiv und versorgt es mit dem Status 0 bzw 1
       </li><br>
     </ul>
  </ul>
  <br> 

</ul>

=end html_DE

=for :application/json;q=META.json 98_readingsWatcher.pm

{
  "abstract": "Module for cyclical watching of readings updates",
  "x_lang": {
    "de": {
      "abstract": "Modul zur zyklische Überwachung von Readings auf Aktualisierung"
    }
  },
  "keywords": [
    "readings",
    "watch",
    "supervision",
    "überwachung"
  ],
  "version": "2.1.0",
  "release_status": "stable",
  "author": [
    "Wzut"
  ],
  "x_fhem_maintainer": [
    "Wzut"
  ],
  "x_fhem_maintainer_github": [
  ],
  "prereqs": {
    "runtime": {
      "requires": {
        "FHEM": 5.00918799,
        "GPUtils": 0,
        "Time::HiRes": 0,
        "List::Util": 0
      },
      "recommends": {
        "FHEM::Meta": 0
      },
      "suggests": {
      }
    }
  }
}
=end :application/json;q=META.json

=cut


