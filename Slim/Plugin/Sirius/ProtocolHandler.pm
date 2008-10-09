package Slim::Plugin::Sirius::ProtocolHandler;

# $Id$

# TODO:
# Test with transcoding
# Test synced
# Test add to favorites
# Detect player gone away, stop updates
# SN web images

use strict;
use base qw(Slim::Player::Protocols::MMS);

use Slim::Music::Info;
use Slim::Networking::Async::HTTP;
use Slim::Networking::SqueezeNetwork;
use Slim::Utils::Misc;
use Slim::Utils::Timers;

use HTTP::Request;
use JSON::XS qw(from_json);
use URI::Escape qw(uri_escape);

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.sirius',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_SIRIUS_MODULE_NAME',
} );

sub audioScrobblerSource { 'R' }

sub getFormatForURL { 'wma' }

sub isAudioURL { 1 }

sub isRemote { 1 }

# Support transcoding
sub new {
	my $class = shift;
	my $args  = shift;

	my $client = $args->{client};
	my $url    = $args->{'song'}->{'streamUrl'};
	
	return unless $url;

	return $class->SUPER::new( {
		client => $client,
		url    => $url,
	} );
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	
	my ($channelId) = $song->currentTrack()->url =~ m{^sirius://(.+)};
	
	# Talk to SN and get the channel info for this station
	my $infoURL = Slim::Networking::SqueezeNetwork->url(
		"/api/sirius/v1/playback/getChannelInfo?channelId=" . $channelId
	);
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		sub {gotChannelInfo($song, @_);},		# use closure to hang onto song reference
		sub {gotChannelInfoError($song, @_);},
		{
			client  => $song->master(),
			params  => {
				channelId     => $channelId,
				callback      => $successCb,
				errorCallback => $errorCb,
			},
			timeout => 60, # Sirius can be pretty slow
		},
	);
	
	$log->debug("Getting channel info from SqueezeNetwork for " . $channelId );
	
	$http->get( $infoURL );
}

sub gotChannelInfo {
	my $song   = shift;
	my $http   = shift;
	my $params = $http->params->{'params'};
	my $url    = $song->currentTrack()->url;
	
	my $info = eval { from_json( $http->content ) };
	
	if ( $@ || ref $info ne 'HASH' ) {
		$info = {
			error => $@ || 'Invalid JSON reponse',
		};
	}
	
	if ( $log->is_debug ) {
		$log->debug( "Got Sirius channel info: " . Data::Dump::dump($info) );
	}
	
	if ( $info->{error} ) {
		# We didn't get the info to play		
		my $title = $http->params->{'client'}->string('PLUGIN_SIRIUS_NO_INFO') . ' (' . $info->{error} . ')';
		$params->{'errorCallback'}->('PLUGIN_SIRIUS_ERROR', $title);
		return;
	}
	
	# Find best stream URL
	my $streamURL;
	my $activityInterval;
	my $bitrate;
	
	for my $stream ( @{ $info->{streams} } ) {
		if ( $stream->{Enabled} eq 'true' ) {
			$streamURL        = $stream->{content};
			$activityInterval = $stream->{ActivityInterval};
			$bitrate          = $stream->{Bitrate} * 1000;
			last;
		}
	}
	
	$streamURL =~ s/^http/mms/;
	
	# Save metadata for this track
	$song->{'streamUrl'} = $streamURL;
	$song->{'bitrate'}   = $bitrate;
	$song->{'coverArt'}  = $info->{logo};
	
	# Include the metadata sub-stream for this station
	$song->{'wmaMetadataStream'} = 2;
	
	# Start a timer to check status at the defined interval
	$log->debug( 'Polling status in ' . $info->{status}->{PollingInterval} . ' seconds' );
	Slim::Utils::Timers::killTimers( $song, \&pollStatus );
	Slim::Utils::Timers::setTimer( 
		$song,
		Time::HiRes::time() + $info->{status}->{PollingInterval},
		\&pollStatus,
		$info->{status},
	);

	# Start a timer to make sure the user remains active
	$log->debug( "Checking activity in $activityInterval seconds" );
	Slim::Utils::Timers::killTimers( $song, \&checkActivity );
	Slim::Utils::Timers::setTimer(
		$song,
		Time::HiRes::time() + $activityInterval,
		\&checkActivity,
		$activityInterval,
	);
	
	$params->{'callback'}->();
}

sub gotChannelInfoError {
	my $song   = shift;
	my $http   = shift;
	
	$http->params->{'params'}->{'errorCallback'}->('PLUGIN_SIRIUS_ERROR', $http->error);
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;
	
	return $class->SUPER::canDirectStream($client, $song->{'streamUrl'}, $class->getFormatForURL());
}

sub parseDirectHeaders {
	my $class   = shift;
	my $client  = shift || return;
	my $url     = shift;
#	my @headers = @_;
	
	my $contentType = 'wma';
	my $bitrate     = $client->streamingSong()->{'bitrate'};
	
	# title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $contentType, undef, undef);
}

sub pollStatus {
	my ( $song, $status ) = @_;
	
	# Make sure we're still playing Sirius
	return if !$song->isActive();
	
	$log->debug("Polling status...");

	my $statusURL = Slim::Networking::SqueezeNetwork->url(
		"/api/sirius/v1/playback/streamStatus?content=" . uri_escape( $status->{content} )
	);
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		sub {gotPollStatus($song, @_);},
		sub {gotPollStatusError($song, @_);},
		{
			client  => $song->master(),
			status  => $status,
			timeout => 60,
		},
	);
	
	$http->get( $statusURL );
}

sub gotPollStatus {
	my $song   = shift;
	my $http   = shift;
	my $status = $http->params('status');
	
	my $info = eval { from_json( $http->content ) };
	
	if ( $@ || ref $info ne 'HASH' ) {
		$info = {
			error => $@ || 'Invalid JSON reponse',
		};
	}
	
	if ( $log->is_debug ) {
		$log->debug( "Got Sirius stream status: " . Data::Dump::dump($info) );
	}
	
	if ( $info->{error} ) {
		# We didn't get the status, try again using the previous poll interval
		$log->error( "Error getting Sirius stream status: " . $info->{error} );
		
		Slim::Utils::Timers::killTimers( $song, \&pollStatus );
		Slim::Utils::Timers::setTimer( 
			$song,
			Time::HiRes::time() + $status->{PollingInterval},
			\&pollStatus,
			$status,
		);
		return;
	}
	
	if ( $info->{Status} ne 'open' ) {
		stopStreaming( $song, 'PLUGIN_SIRIUS_STOPPING_UNAUTHORIZED' );
		return;
	}
	
	# Add the status URL, for some reason it's not included in the status response
	$info->{content} = $status->{content};
	
	$log->debug( "Sirius stream status OK, polling again in " . $info->{PollingInterval} );
	
	# Stream is OK, setup next poll
	Slim::Utils::Timers::killTimers( $song, \&pollStatus );
	Slim::Utils::Timers::setTimer( 
		$song,
		Time::HiRes::time() + $info->{PollingInterval},
		\&pollStatus,
		$info,
	);
}

sub gotPollStatusError {
	my $song   = shift;
	my $http   = shift;
	my $error  = $http->error;
	my $status = $http->params('status');
	
	$log->error( "Error getting Sirius stream status: " . $error );
	
	# Retry getting status later
	Slim::Utils::Timers::killTimers( $song, \&pollStatus );
	Slim::Utils::Timers::setTimer( 
		$song,
		Time::HiRes::time() + $status->{PollingInterval},
		\&pollStatus,
		$status,
	);
}
	

sub checkActivity {
	my ( $song, $interval ) = @_;
	
	# Make sure we're still playing Sirius
	return unless $song->isActive();
	
	# Check for activity within last $interval seconds
	# If idle time has been exceeded, stop playback
	my $now          = Time::HiRes::time();
	my $lastActivity = $song->master()->lastActivityTime();
	if ( $now - $lastActivity >= $interval ) {
		$log->debug("User has been inactive for at least $interval seconds, stopping");
		stopStreaming( $song, 'PLUGIN_SIRIUS_STOPPING_INACTIVE' );
		return;
	}

	if ( $log->is_debug ) {
		my $inactive  = $now - $lastActivity;
		my $nextCheck = $interval - $inactive;
		$log->debug( "User has been inactive for only $inactive seconds, next check in $nextCheck" );
	}
	
	# Check again when the user would next be inactive for $interval seconds
	Slim::Utils::Timers::setTimer(
		$song,
		Time::HiRes::time() + ( $interval - ( $now - $lastActivity ) ),
		\&checkActivity,
		$interval,
	);

}

sub stopStreaming {
	my ( $song, $string ) = @_;
	
	my $client     = $song->master();
	
	# Change the stream title to the error message
	Slim::Music::Info::setCurrentTitle( $song->currentTrack()->url, $client->string($string) );
	
	$client->update();
	
	# Kill all timers
	Slim::Utils::Timers::killTimers( $song, \&pollStatus );
	Slim::Utils::Timers::killTimers( $song, \&checkActivity );
	
	$client->execute( [ 'stop' ] );
}

sub parseMetadata {
	my ( $class, $client, $song, $metadata ) = @_;
	
	# If we have ASF_Command_Media, process it here, otherwise let parent handle it
	my $guid;
	map { $guid .= $_ } unpack( 'H*', substr $metadata, 0, 16 );
	
	if ( $guid ne '59dacfc059e611d0a3ac00a0c90348f6' ) { # ASF_Command_Media
		return $class->SUPER::parseMetadata( $client, $song, $metadata );
	}
		
	# Format of the metadata stream is:
	# TITLE <title>|ARTIST <artist>\0
	
	# WMA text is in UTF-16, if we can't decode it, just wait for more data
	# Cut off first 24 bytes (16 bytes GUID and 8 bytes object_size)
	$metadata = eval { Encode::decode('UTF-16LE', substr( $metadata, 24 ) ) } || return;
	
	#$log->debug( "ASF_Command_Media: $metadata" );
	
	my ($artist, $title);
	
	if ( $metadata =~ /TITLE\s+([^|]+)/ ) {
		$title = $1;
	}
	
	if ( $metadata =~ /ARTIST\s([^\0]+)/ ) {
		$artist = $1;
	}
	
	if ( $artist || $title ) {
		if ( $artist && $artist ne $title ) {
			$title = "$artist - $title";
		}
		
		Slim::Music::Info::setDelayedTitle( $song->master(),  $song->currentTrack()->url, $title );
	}
	
	return;
}

# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	my ($artist, $title);
	# Return artist and title if the metadata looks like Artist - Title
	if ( my $currentTitle = Slim::Music::Info::getCurrentTitle( $client, $url ) ) {
		my @dashes = $currentTitle =~ /( - )/g;
		if ( scalar @dashes == 1 ) {
			($artist, $title) = split / - /, $currentTitle;
		}

		else {
			$title = $currentTitle;
		}
	}
	
	# try to find song
	my $song = $client->streamingSong();
	
	my $bitrate;
	my $logo;
	
	if ($song && $song->currentTrack()->url eq $url || $song->{'streamUrl'} eq $url) {
		my $bitrate = $song->{'bitrate'} / 1000;
		my $logo    = $song->{'coverArt'};
	}
	
	$bitrate ||= 128;
	$logo    ||= $class->getIcon($url);
	
	return {
		artist  => $artist,
		title   => $title,
		cover   => $logo,
		bitrate => $bitrate . 'k CBR',
		type    => 'WMA (Sirius)',
	};
}

sub getIcon {
	return Slim::Plugin::Sirius::Plugin->_pluginDataFor('icon');
}

# SN only
sub reinit {
	my ( $class, $client, $playlist ) = @_;
	
	my $url = $playlist->[0];
	
	# XXX: To properly re-init Sirius we need to:
	# * Reconnect to WMA metadata stream, this may not
	#   work due to the timeout on the Akamai URLs
	# * Restart pollStatus timer
	# * Restart checkActivity timer
	
	$log->debug( "Reinit Sirius for $url" );
	
	# Ignore the check for playing status
	$client->ignoreCheckPlayingStatus(1);
	
	# For now, just restart the stream
	$client->execute( [ 'playlist', 'play', $url ] );
}    

1;
