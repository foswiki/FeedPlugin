# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# FeedPlugin is Copyright (C) 2016-2022 Michael Daum http://michaeldaumconsulting.com
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
  my $url = $params->{_DEFAULT} || $params->{href};
  return _inlineError("Error: no url specified") unless $url;


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

  my $error;
  my $res;
  try {
    $res = _ua->get($url);

    throw Error::Simple("error fetching url") 
      unless $res;

    unless ($res->is_success) {
      _writeDebug("url=$url, http error=".$res->status_line);
      throw Error::Simple("http error fetching $url: ".$res->code." - ".$res->status_line);
    }

  } catch Error::Simple with {
    $error = shift;
  };
  return _inlineError($error) if defined $error;

  my $text = $res->decoded_content();
  $text = HTML::Entities::decode_entities($text) if Foswiki::Func::isTrue($params->{decode});
  my $since = _parseTime($params->{since} // 0);

  my $feed;
  try {
    $feed = XML::Feed->parse(\$text) or $error = XML::Feed->errstr;
  } otherwise {
    $error = shift;
    $error =~ s/ at .*$//;
  };
  return _inlineError("Error parsing feed: $error") if defined $error;

  my $format = $params->{format} || '   * [[$link][$title]]$n';
  my $header = $params->{header} || '';
  my $footer = $params->{footer} || '';
  my $separator = $params->{separator} || '';
  my $limit = $params->{limit} || 0;
  my $skip = $params->{skip} || 0;
  my $exclude = $params->{exclude};
  my $include = $params->{include};

  my @result = ();
  my $index = 0;
  foreach my $entry ($feed->entries) {
    $index++;
    my $title = _decode($entry->title);

    next if $exclude && $title =~ /$exclude/;
    next if $include && $title !~ /$include/;

    last if $limit && $index > ($limit+$skip);
    next if $skip && $index <= $skip;

    my $line = $format;
    my $category = _decode(join(", ", $entry->category()) || '');
    my $tags = _decode(join(", ", $entry->tags()) || '');
    my $content = "<noautolink>"._decode($entry->content->body())."</noautolink>";
    my $summary = _decode($entry->summary->body()) // '';
    my $issued = $entry->issued;
    $issued = $issued->epoch if defined $issued;
    my $modified = $entry->modified;
    $modified = $modified->epoch if defined $modified;

    next if $since && $issued && $issued < $since;
    next if $since && $modified && $modified < $since;

    $line =~ s/\$author\b/_decode($entry->author)/ge;
    $line =~ s/\$base\b/_decode($entry->base)/ge;
    $line =~ s/\$category\b/$category/g;
    $line =~ s/\$content\b/$content/g;
    $line =~ s/\$id\b/_decode($entry->id)/ge;
    $line =~ s/\$index\b/$index/g;
    $line =~ s/\$(?:issued|date)(?:\((.*?)\))?/defined($issued)?Foswiki::Time::formatTime($issued, $1 || '$day $month $year'):""/ge;
    $line =~ s/\$link\b/_decode($entry->link)/ge;
    $line =~ s/\$modified(?:\((.*?)\))?/defined($modified)?Foswiki::Time::formatTime($modified, $1 || '$day $month $year'):""/ge;
    $line =~ s/\$summary\b/$summary/g;
    $line =~ s/\$tags\b/$tags/g;
    $line =~ s/\$title\b/$title/g;
    $line =~ s/%(\w)/%<nop>$1/g;
    push @result, $line;
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

sub _parseTime {
  my $string = shift;

  return unless defined $string;
  return $string if $string =~ /^\d+$/;
  return Foswiki::Time::parseTime($string, undef, {lang => "en"});
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
