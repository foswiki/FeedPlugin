# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# FeedPlugin is Copyright (C) 2016 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::FeedPlugin::Core;

use strict;
use warnings;

use Foswiki::Func ();
use Foswiki::Time ();
use XML::Feed();
use URI ();
use Cache::FileCache ();
use Digest::MD5 ();
use Error qw(:try);

use constant TRACE => 0; # toggle me

=begin TML

---+ package FeedPlugin::Core

=cut

=begin TML

---++ new()

=cut

sub new {
  my $class = shift;

  my $this = bless({
    cacheExpire => $Foswiki::cfg{FeedPlugin}{CacheExpire} || '1 d',
    cacheDir => Foswiki::Func::getWorkArea('FeedPlugin').'/cache',
    timeout => $Foswiki::cfg{FeedPlugin}{TimeOut} || 10,
    agent => $Foswiki::cfg{FeedPlugin}{Agent} || 'Mozilla/5.0 (compatible; Konqueror/4.5; Linux; X11; en_US) KHTML/4.5.5 (like Gecko) Kubuntu',
    @_
  }, $class);

  return $this;
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "FeedPlugin::Core - $_[0]\n";
}

sub _inlineError {
  return "<span class='foswikiAlert'>".$_[0]."</span>";
}

sub _cache {
  my $this = shift;

  unless ($this->{cache}) {
    $this->{cache} = new Cache::FileCache({
      default_expires_in => $this->{cacheExpire},
      cache_root 	=> $this->{cacheDir},
      directory_umask => 077,
    });
  }

  return $this->{cache};
}

=begin TML

---++ clearCache()

=cut

sub clearCache {
  my $this = shift;

  $this->_cache->clear;
}

=begin TML

---++ purgeCache()

=cut

sub purgeCache {
  my $this = shift;

  $this->_cache->purge;
}

=begin TML

---++ getExternalResource($url, $expire) -> ($content, $type)

=cut

sub getExternalResource {
  my ($this, $url, $expire) = @_;

  my $cache = $this->_cache;
  my $content;
  my $contentType;

  $url =~ s/\/$//;

  my $bucket = $cache->get(_cache_key($url));

  if (defined $bucket) {
    $content = $bucket->{content};
    $contentType = $bucket->{type};
    _writeDebug("found content for $url in cache contentType=$contentType");
  }

  unless (defined $content) { 
    my $client = $this->_client;
    my $res = $client->get($url);

    throw Error::Simple("error fetching url") 
      unless $res;

    unless ($res->is_success) {
      _writeDebug("url=$url, http error=".$res->status_line);
      throw Error::Simple("http error fetching $url: ".$res->code." - ".$res->status_line);
    }

    _writeDebug("http status=".$res->status_line);

    $content = $res->decoded_content();
    $contentType = $res->header('Content-Type');
    _writeDebug("content type=$contentType");

    _writeDebug("caching content for $url");
    $cache->set(_cache_key($url), {content => $content, type => $contentType}, $expire);
  }

  return ($content, $contentType) if wantarray;
  return $content;
}

sub _client {
  my $this = shift;

  unless (defined $this->{client}) {
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new;
    $ua->timeout($this->{timeout});
    $ua->agent($this->{agent});

    my $attachLimit = Foswiki::Func::getPreferencesValue('ATTACHFILESIZELIMIT') || 0;
    $attachLimit =~ s/[^\d]//g;
    if ($attachLimit) {
      $attachLimit *= 1024;
      $ua->max_size($attachLimit);
    }

    my $proxy = $Foswiki::cfg{PROXY}{HOST};
    if ($proxy) {
      my $port = $Foswiki::cfg{PROXY}{PORT};
      $proxy .= ':' . $port if $port;
      $ua->proxy([ 'http', 'https' ], $proxy);

      my $proxySkip = $Foswiki::cfg{PROXY}{SkipProxyForDomains};
      if ($proxySkip) {
        my @skipDomains = split(/\s*,\s*/, $proxySkip);
        $ua->no_proxy(@skipDomains);
      }
    }

    $ua->ssl_opts(
      verify_hostname => 0,    # SMELL
    );

    $this->{client} = $ua;
  }

  return $this->{client}
}

sub _cache_key {
  return _untaint(Digest::MD5::md5_hex($_[0]));
}

sub _untaint {
  my $content = shift;
  if (defined $content && $content =~ /^(.*)$/s) {
    $content = $1;
  }
  return $content;
}

=begin TML

---++ FEED()

handles the %FEED macro

=cut

sub FEED {
  my ($this, $session, $params, $topic, $web) = @_;

  _writeDebug("called FEED()");
  my $url = $params->{_DEFAULT} || $params->{href};
  return _inlineError("Error: no url specified") unless $url;


  my $discover = Foswiki::Func::isTrue("discover", 0);
  if ($discover) {
    my @feeds = XML::Feed->find_feeds($url);
    return _inlineError("Error: no feeds found") unless @feeds;

    # SMELL: take the first one
    $url = shift @feeds;
  } 

  my $request = Foswiki::Func::getRequestObject();
  my $doRefresh = $request->param("refresh") || '';
  $this->_cache->remove(_cache_key($url)) if $refresh =~ /^(on|feed)$/;
  my $expire = $params->{refresh};

  my $error;
  my $text;
  try {
    $text = $this->getExternalResource($url, $expire);
  }
  catch Error::Simple with {
    $error = shift;
  };
  return _inlineError($error) if defined $error;

  my $feed = XML::Feed->parse(\$text) or return _inlineError("Error: ". XML::Feed->errstr);;

  my $format = $params->{format} || '   * [[$link][$title]]$n';
  my $header = $params->{header} || '';
  my $footer = $params->{footer} || '';
  my $separator = $params->{separator} || '';
  my $limit = $params->{limit} || 0;
  my $skip = $params->{skip} || 0;

  my @result = ();
  my $index = 0;
  foreach my $entry ($feed->entries) {
    $index++;
    last if $limit && $index > ($limit+$skip);
    next if $skip && $index <= $skip;
    my $line = $format;

    my $category = join(", ", $entry->category()) || '';
    my $tags = join(", ", $entry->tags()) || '';
    my $content = "<noautokink>".$entry->content->body()."</noautolink>";
    my $summary = $entry->summary->body();

    $line =~ s/\$author/$entry->author/g;
    $line =~ s/\$base/$entry->base/ge;
    $line =~ s/\$category/$category/g;
    $line =~ s/\$content/$content/g;
    $line =~ s/\$id/$entry->id/ge;
    $line =~ s/\$index/$index/g;
    $line =~ s/\$issued(?:\((.*?)\))?/Foswiki::Time::formatTime($entry->issued->epoch, $1 || '$day $month $year')/ge;
    $line =~ s/\$link/$entry->link/ge;
    $line =~ s/\$modified(?:\((.*?)\))?/Foswiki::Time::formatTime($entry->modified->epoch, $1 || '$day $month $year')/ge;
    $line =~ s/\$summary/$summary/g;
    $line =~ s/\$tags/$tags/g;
    $line =~ s/\$title/$entry->title/ge;

    $line =~ s/%(\w)/%<nop>$1/g;
    push @result, $line;
  }
  return "" unless @result;

  my $result = $header.join($separator, @result).$footer;

  $result =~ s/\$feed_author/$feed->author/ge;
  $result =~ s/\$feed_base/$feed->base/ge;
  $result =~ s/\$feed_copyright/$feed->copyright/ge;
  $result =~ s/\$feed_format/$feed->format/ge;
  $result =~ s/\$feed_generator/$feed->generator/ge;
  $result =~ s/\$feed_language/$feed->language/ge;
  $result =~ s/\$feed_link/$feed->link/ge;
  $result =~ s/\$feed_modified/$feed->modified/ge;
  $result =~ s/\$feed_modified(?:\((.*?)\))?/Foswiki::Time::formatTime($feed->modified->epoch, $1 || '$day $month $year')/ge;
  $result =~ s/\$feed_tagline/$feed->tagline/ge;
  $result =~ s/\$feed_title/$feed->title/ge;

  return Foswiki::Func::decodeFormatTokens($result);
}

1;
