# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# FeedPlugin is Copyright (C) 2016-2024 Michael Daum http://michaeldaumconsulting.com
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
use Foswiki::Contrib::CacheContrib ();
use XML::Feed();
use Encode ();
use HTML::Entities ();
use Error qw(:try);
#use Data::Dump qw(dump);

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

sub _ua {
  return Foswiki::Contrib::CacheContrib::getUserAgent("FeedPlugin");
}

=begin TML

---++ FEED()

handles the %FEED macro

=cut

sub FEED {
  my ($this, $session, $params, $topic, $web) = @_;

  _writeDebug("called FEED()");

  my $feed;
  my $error;

  try {
    $feed = $this->getFeed($params);
  } catch Error::Simple with {
    $error = shift;
  };
  return _inlineError($error) if defined $error;

  return $this->formatFeed($params, $feed);
}

sub getFeed {
  my ($this, $params) = @_;

  my $url = $params->{_DEFAULT} || $params->{href};
  throw Error::Simple("Error: no url specified") unless $url;

  my $discover = Foswiki::Func::isTrue($params->{discover}, 0);
  if ($discover) {
    my @feeds = XML::Feed->find_feeds($url);
    return _inlineError("Error: no feeds found") unless @feeds;

    # SMELL: take the first one
    $url = shift @feeds;
  } 

  my $expire = $params->{refresh} // $params->{expire} // $Foswiki::cfg{FeedPlugin}{CacheExpire} // "1 d";

  my $request = Foswiki::Func::getRequestObject();
  my $doRefresh = $request->param("refresh") || '';
  my $cache = _ua->getCache($expire);
  $cache->remove($url) if $doRefresh =~ /^(on|feed)$/;

  my $res = _ua->get($url);

  throw Error::Simple("error fetching url") 
    unless $res;

  unless ($res->is_success) {
    _writeDebug("url=$url, http error=".$res->status_line);
    throw Error::Simple("http error fetching $url: ".$res->code." - ".$res->status_line);
  }

  my $text = $res->decoded_content();
  $text = _decodeEntities($text) if Foswiki::Func::isTrue($params->{decode});

  my $feed;
  my $error;
  try {
    $feed = XML::Feed->parse(\$text) or $error = XML::Feed->errstr;
  } otherwise {
    $error = shift;
    $error =~ s/ at \/.*$//;

    my $html = $text;
    my $line = 1;
    $html = '00000: ' . $html;
    $html =~ s/\n/"\n".(sprintf "\%05d", $line++).": "/ge;
    $error .= "\n\n<verbatim>$html</verbatim>";
  };

  throw Error::Simple("Error parsing feed: $error") if $error;

  return $feed;
}

sub formatFeed {
  my ($this, $params, $feed) = @_;

  my $header = $params->{header} || '';
  my $footer = $params->{footer} || '';
  my $separator = $params->{separator} || '';
  my $limit = $params->{limit} || 0;
  my $skip = $params->{skip} || 0;
  my $exclude = $params->{exclude};
  my $include = $params->{include};
  my $since = _parseTime($params->{since} // 0);

  my @result = ();
  my $index = 0;
  foreach my $entry ($feed->entries) {
    $index++;

    my $title = _decode($entry->title);

    next if $exclude && $title =~ /$exclude/;
    next if $include && $title !~ /$include/;

    last if $limit && $index > ($limit + $skip);
    next if $skip && $index <= $skip;

    my $issued = $entry->issued;
    $issued = $issued->epoch if defined $issued;
    my $modified = $entry->modified;
    $modified = $modified->epoch if defined $modified;

    next if $since && $issued && $issued < $since;
    next if $since && $modified && $modified < $since;

    my $format = $params->{format} || '   * [[$link][$title]]$n';

    my $line = $this->formatEntry($format, $entry);
    next unless $line;
  
    $line =~ s/\$index\b/$index/g;

    push @result, $line if $line;
  }
  return "" unless @result;

  my $result = $header.join($separator, @result).$footer;

  $result =~ s/\$feed_author/_decode($feed->author)/ge;
  $result =~ s/\$feed_base/_decode($feed->base)/ge;
  $result =~ s/\$feed_copyright/_decode($feed->copyright)/ge;
  $result =~ s/\$feed_format/_decode($feed->format)/ge;
  $result =~ s/\$feed_generator/_decode($feed->generator)/ge;
  $result =~ s/\$feed_language/_decode($feed->language)/ge;
  $result =~ s/\$feed_link/_decode($feed->link)/ge;
  $result =~ s/\$feed_modified/_decode($feed->modified)/ge;
  $result =~ s/\$feed_modified(?:\((.*?)\))?/Foswiki::Time::formatTime($feed->modified->epoch, $1 || '$day $month $year')/ge;
  $result =~ s/\$feed_tagline/_decode($feed->tagline)/ge;
  $result =~ s/\$feed_title/_decode($feed->title)/ge;

  return Foswiki::Func::decodeFormatTokens($result);
}

sub formatEntry {
  my ($this, $format, $entry) = @_;

  my $title = _decode($entry->title);

  my $category = _decode(join(", ", $entry->category()) || '');
  my $tags = _decode(join(", ", $entry->tags()) || '');
  my $content = "<noautolink>" . _decode($entry->content->body()) . "</noautolink>";
  my $summary = _decode($entry->summary->body()) // '';
  my $issued = $entry->issued;
  my $modified = $entry->modified;

  $format =~ s/\$author\b/_decode($entry->author)/ge;
  $format =~ s/\$base\b/_decode($entry->base)/ge;
  $format =~ s/\$category\b/$category/g;
  $format =~ s/\$content\b/$content/g;
  $format =~ s/\$id\b/_decode($entry->id)/ge;
  $format =~ s/\$(?:issued|date)(?:\((.*?)\))?/defined($issued)?Foswiki::Time::formatTime($issued, $1 || '$day $month $year'):""/ge;
  $format =~ s/\$link\b/_decode($entry->link)/ge;
  $format =~ s/\$modified(?:\((.*?)\))?/defined($modified)?Foswiki::Time::formatTime($modified, $1 || '$day $month $year'):""/ge;
  $format =~ s/\$summary\b/$summary/g;
  $format =~ s/\$tags\b/$tags/g;
  $format =~ s/\$title\b/$title/g;
  $format =~ s/%(\w)/%<nop>$1/g;
  
  return $format;
}

sub _parseTime {
  my $string = shift;

  return unless defined $string;
  return $string if $string =~ /^\d+$/;
  return Foswiki::Time::parseTime($string, undef, {lang => "en"});
}

sub _decodeEntities {
  my $string = shift;

  return "" unless defined $string;
  $string = HTML::Entities::decode_entities($string);

  # undo some
  $string =~ s/ & /&amp;/g;

  return $string;
}

sub _decode {
  my $string = shift;

  return "" unless defined $string;
  return $string; ### SMELL

  return Encode::decode_utf8($string);
}

sub _encode {
  my $string = shift;

  return "" unless defined $string;
  return Encode::encode_utf8($string);
}

1;
