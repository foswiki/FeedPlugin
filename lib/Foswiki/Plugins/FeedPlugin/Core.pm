# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# FeedPlugin is Copyright (C) 2016-2020 Michael Daum http://michaeldaumconsulting.com
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

  my $request = Foswiki::Func::getRequestObject();
  my $doRefresh = $request->param("refresh") || '';
  Foswiki::Contrib::CacheContrib::getCache("UserAgent")->remove($url) if $doRefresh =~ /^(on|feed)$/;

  my $error;
  my $res;
  try {
    $res = Foswiki::Contrib::CacheContrib::getExternalResource($url);

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

    my $category = _encode(join(", ", $entry->category()) || '');
    my $tags = _encode(join(", ", $entry->tags()) || '');
    my $content = "<noautolink>"._encode($entry->content->body())."</noautolink>";
    my $summary = _encode($entry->summary->body());
    my $issued = $entry->issued;
    $issued = $issued->epoch if defined $issued;
    my $modified = $entry->modified;
    $modified = $modified->epoch if defined $modified;

    $line =~ s/\$author/_encode($entry->author)/ge;
    $line =~ s/\$base/_encode($entry->base)/ge;
    $line =~ s/\$category/$category/g;
    $line =~ s/\$content/$content/g;
    $line =~ s/\$id/_encode($entry->id)/ge;
    $line =~ s/\$index/$index/g;
    $line =~ s/\$(?:issued|date)(?:\((.*?)\))?/defined($issued)?Foswiki::Time::formatTime($issued, $1 || '$day $month $year'):""/ge;
    $line =~ s/\$link/_encode($entry->link)/ge;
    $line =~ s/\$modified(?:\((.*?)\))?/defined($modified)?Foswiki::Time::formatTime($modified, $1 || '$day $month $year'):""/ge;
    $line =~ s/\$summary/$summary/g;
    $line =~ s/\$tags/$tags/g;
    $line =~ s/\$title/_encode($entry->title)/ge;

    $line =~ s/%(\w)/%<nop>$1/g;
    push @result, $line;
  }
  return "" unless @result;

  my $result = $header.join($separator, @result).$footer;

  $result =~ s/\$feed_author/_encode($feed->author)/ge;
  $result =~ s/\$feed_base/_encode($feed->base)/ge;
  $result =~ s/\$feed_copyright/_encode($feed->copyright)/ge;
  $result =~ s/\$feed_format/_encode($feed->format)/ge;
  $result =~ s/\$feed_generator/_encode($feed->generator)/ge;
  $result =~ s/\$feed_language/_encode($feed->language)/ge;
  $result =~ s/\$feed_link/_encode($feed->link)/ge;
  $result =~ s/\$feed_modified/_encode($feed->modified)/ge;
  $result =~ s/\$feed_modified(?:\((.*?)\))?/Foswiki::Time::formatTime($feed->modified->epoch, $1 || '$day $month $year')/ge;
  $result =~ s/\$feed_tagline/_encode($feed->tagline)/ge;
  $result =~ s/\$feed_title/_encode($feed->title)/ge;

  return Foswiki::Func::decodeFormatTokens($result);
}

sub _encode {
  my $string = shift;
  $string = Encode::encode($Foswiki::cfg{Site}{CharSet}, $string) unless $Foswiki::UNICODE;
  return $string;
}

1;
