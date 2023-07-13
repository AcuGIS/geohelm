=head1 geoserver-lib.pl

Functions for managing Geoserver webapp configuration files.

  foreign_require("geoserver", "geoserver-lib.pl");
  @sites = geoserver::list_geoserver_websites()

=cut

BEGIN { push(@INC, ".."); };
use warnings;
use WebminCore;
use File::Copy;
init_config();

require './tomcat-lib.pl';
use File::Basename;

foreign_require('software', 'software-lib.pl');

sub get_geoserver_config
{
my $lref = &read_file_lines($config{'geoserver_conf'});
my @rv;
my $lnum = 0;
foreach my $line (@$lref) {
    my ($n, $v) = split(/\s+/, $line, 2);
    if ($n) {
      push(@rv, { 'name' => $n, 'value' => $v, 'line' => $lnum });
      }
    $lnum++;
    }
return @rv;
}

sub get_acugeo_versions{
	my %tver = &get_catalina_version();
	my %gver = &get_geoserver_version();


	$tver{'geoserver_ver'}	 = $gver{'number'};
	$tver{'geoserver_build'} = $gver{'jdk'};
	return %tver;
}

sub process_file_source{
	my $file = '';

	if (($in{'source'} == 0) && ($in{'file'} ne "")) {	# from local file
		&error_setup(&text('source_err0', $in{'file'}));
		$file = $in{'file'};
		if (!(-r $file)){
			&error($text{'source_err0'});
		}

	}elsif (($in{'source'} == 1) && ($in{'upload_filename'} ne "")) {	# from uploaded file
		&error_setup($text{'source_err1'});
		$need_unlink = 1;
		if ($no_upload) {
			&error($text{'source_err1.2'});
		}
		$file = transname(file_basename($in{'upload_filename'}));
		open(MOD, ">$file");
		binmode(MOD);
		print MOD $in{'upload'};
		close(MOD);

	}elsif ($in{'source'} == 2 and $in{'url'} ne '') {	# from ftp or http url (possible third-party)
		$url = $in{'url'};
		&error_setup(&text('source_err2', $url));
		$file = &transname(file_basename($url));
		$need_unlink = 1;
		my $error;
		$progress_callback_url = $url;
		if ($url =~ /^(http|https):\/\/([^\/]+)(\/.*)$/) {
			$ssl = $1 eq 'https';
			$host = $2; $page = $3; $port = $ssl ? 443 : 80;
			if ($host =~ /^(.*):(\d+)$/) { $host = $1; $port = $2; }
			my %cookie_headers = ('Cookie'=>'oraclelicense=accept-securebackup-cookie');
			&http_download($host, $port, $page, $file, \$error,
				       \&progress_callback, $ssl, undef, undef, 0, 0, 1, \%cookie_headers);
		} elsif (
			$url =~ /^ftp:\/\/([^\/]+)(:21)?\/(.*)$/) {
			$host = $1; $ffile = $3;
			&ftp_download($host, $ffile, $file, \$error, \&progress_callback);
		}else {
			&error($text{'source_err3'});
		}
		&error($error) if ($error);
	}
	return $file;
}

sub exec_cmd{
	my $cmd = $_[0];
	my $cmd_out='';

	my $rv = &execute_command($cmd, undef, \$cmd_out, \$cmd_out, 0, 0);
	if($cmd_out){
  	$cmd_out = &html_escape($cmd_out);
  	$cmd_out =~ s/[\r\n]/<\/br>/g;
  	print $cmd_out;
  }
  return $rv;
}

sub unzip_me{
	my $file  = $_[0];
	my @suffixlist = ('\.zip');
	($file_name,$path,$lib_suffix) = fileparse($file,@suffixlist);

	my $unzip_dir = "/tmp/.webmin/$file_name";

	&make_dir($unzip_dir, 0754, 1);

	my $unzip_out;
	my $unzip_err;
	print "<hr>Unzipping to $unzip_dir ...<br>";
	exec_cmd("unzip -u \"$file\" -d \"$unzip_dir\"");

	return $unzip_dir;
}

sub download_file{
	my $url = $_[0];

	my ($proto, $x, $host, $path) = split('/', $url, 4);
	my @paths = split('/', $url);
	my $filename = $paths[-1];
	if($filename eq ''){
		$filename = 'index.html';
	}

	my $sslmode = $proto eq 'https:';
	my $port = 80;
	if($sslmode){
		$port = 443;
	}

	&error_setup(&text('install_err3', $url));
	my $tmpfile = &transname($filename);
	$progress_callback_url = $url;

	&http_download($host, $port, '/'.$path, $tmpfile, \$error, \&progress_callback, $sslmode);

	if($error){
		print &html_escape($error);
		return '';
	}
	return $tmpfile;
}

sub search_pkg{
  my $pattern = $_[0];

  my @avail = ();
  if (defined(&software::update_system_search)) {
  	# Call the search function
    @avail = &software::update_system_search($pattern);
  } else {
  	# Scan through list manually
  	@avail = &software::update_system_available();
  	@avail = grep { $_->{'name'} =~ /\Q$pattern\E/i } @avail;
  }
  return sort @avail;
}

sub get_geoserver_version
{
	local %version;
	my %manifest;
	my $catalina_home = get_catalina_home();

	read_file_cached("$catalina_home/webapps/geoserver/META-INF/MANIFEST.MF", \%manifest, undef, undef, ":");

	($version{'number'}	= $manifest{'Implementation-Version'}) =~ s/[\s\r\n]+//g;
	($version{'jdk'}	= $manifest{'Build-Jdk'}) =~ s/[\s\r\n]+//g;

	return %version;
}

sub get_latest_geoserver_ver(){
	my $error;
	my $geo_version = shift;


	$url = "http://geoserver.org/";
	$tmpfile = &transname("page");
	&error_setup(&text('install_err3', $url));

	&http_download("geoserver.org", 80, "/", $tmpfile, \$error);

	#Parse Stable Version
	open(my $fb, '<', $tmpfile) or &webmin_log("open:$!");
	while (my $line = <$fb>){
		#<li><a href="/release/stable">2.11.0</a></li>
		if($line =~ /<li><a\s+href="\/release\/stable">([0-9\.]+)<\/a>/i){
			$geo_version = $1;
			last;
		}
	}
	close $fb;

	return $geo_version;
}

1;
