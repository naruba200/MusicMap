// Unit tests for the pure-Dart RSS/Atom parser (M4, FR-21/23).

import 'package:flutter_test/flutter_test.dart';
import 'package:music_map/data/news/rss_parser.dart';

const _rss = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
  <channel>
    <title>Test Feed</title>
    <item>
      <title>Band X announces tour</title>
      <link>https://example.com/1</link>
      <pubDate>Mon, 19 Oct 2026 07:00:00 +0000</pubDate>
      <description><![CDATA[<p>Band X hits the <b>road</b>.</p>]]></description>
      <media:content url="https://example.com/img1.jpg" medium="image"/>
    </item>
    <item>
      <title>Bad date item</title>
      <link>https://example.com/2</link>
      <pubDate>not a date</pubDate>
      <description>Short.</description>
    </item>
    <item>
      <title>No link item</title>
      <description>Should be skipped.</description>
    </item>
  </channel>
</rss>
''';

const _atom = '''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Feed</title>
  <entry>
    <title>Album review: Y</title>
    <link href="https://example.com/a1"/>
    <published>2026-10-18T12:00:00Z</published>
    <summary>Great record.</summary>
  </entry>
</feed>
''';

void main() {
  group('parseFeed (RSS)', () {
    test('parses items with title/link/date/image/summary', () {
      final articles = parseFeed(_rss, 'test', 'Test');
      expect(articles.length, 2); // no-link item skipped

      final first = articles[0];
      expect(first.title, 'Band X announces tour');
      expect(first.link, 'https://example.com/1');
      expect(first.publishedAt?.toUtc(),
          DateTime.utc(2026, 10, 19, 7, 0, 0));
      expect(first.imageUrl, 'https://example.com/img1.jpg');
      expect(first.summary, 'Band X hits the road.');
      expect(first.sourceId, 'test');
    });

    test('bad dates become null instead of throwing', () {
      final articles = parseFeed(_rss, 'test', 'Test');
      expect(articles[1].publishedAt, isNull);
    });

    test('leading whitespace before the declaration is tolerated', () {
      final articles = parseFeed('\n  $_rss', 'test', 'Test');
      expect(articles.length, 2);
    });

    test('garbage input returns empty, never throws', () {
      expect(parseFeed('not xml at all', 'test', 'Test'), isEmpty);
      expect(parseFeed('', 'test', 'Test'), isEmpty);
    });
  });

  group('parseFeed (Atom)', () {
    test('parses entries', () {
      final articles = parseFeed(_atom, 'test', 'Test');
      expect(articles.length, 1);
      expect(articles[0].title, 'Album review: Y');
      expect(articles[0].link, 'https://example.com/a1');
      expect(articles[0].publishedAt?.toUtc(),
          DateTime.utc(2026, 10, 18, 12, 0, 0));
    });
  });

  group('round-trip', () {
    test('toJson/fromJson preserves fields', () {
      final articles = parseFeed(_rss, 'test', 'Test');
      final back =
          NewsArticle.fromJson(articles[0].toJson());
      expect(back.title, articles[0].title);
      expect(back.link, articles[0].link);
      expect(back.imageUrl, articles[0].imageUrl);
      expect(back.publishedAt?.toUtc(),
          articles[0].publishedAt?.toUtc());
    });
  });
}
