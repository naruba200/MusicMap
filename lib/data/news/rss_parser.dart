// Pure-Dart RSS 2.0 + Atom parser (FR-21, FR-23). Defensive by design:
// malformed dates → null (sort last), missing fields → skipped item only
// if title or link is missing.

import 'package:xml/xml.dart';

class NewsArticle {
  final String title;
  final String link;
  final String sourceId;
  final String sourceName;
  final DateTime? publishedAt;
  final String? imageUrl;
  final String? summary;

  const NewsArticle({
    required this.title,
    required this.link,
    required this.sourceId,
    required this.sourceName,
    this.publishedAt,
    this.imageUrl,
    this.summary,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'link': link,
        'sourceId': sourceId,
        'sourceName': sourceName,
        if (publishedAt != null)
          'publishedAt': publishedAt!.toIso8601String(),
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (summary != null) 'summary': summary,
      };

  factory NewsArticle.fromJson(Map<String, dynamic> json) => NewsArticle(
        title: json['title'] as String? ?? '',
        link: json['link'] as String? ?? '',
        sourceId: json['sourceId'] as String? ?? '',
        sourceName: json['sourceName'] as String? ?? '',
        publishedAt:
            DateTime.tryParse(json['publishedAt'] as String? ?? ''),
        imageUrl: json['imageUrl'] as String?,
        summary: json['summary'] as String?,
      );
}

/// Parse an RSS 2.0 or Atom feed into articles. Never throws — returns
/// whatever could be salvaged, or an empty list.
List<NewsArticle> parseFeed(
    String xmlString, String sourceId, String sourceName) {
  try {
    // Some feeds emit leading whitespace or a BOM before the XML
    // declaration, which strict parsers reject.
    final clean = xmlString.trimLeft().replaceFirst(
        RegExp('^\uFEFF'), '');
    final doc = XmlDocument.parse(clean);
    final root = doc.rootElement;
    final items = root.name.local == 'feed'
        ? root.findElements('entry')
        : root.descendantElements.where((e) => e.name.local == 'item');
    final out = <NewsArticle>[];
    for (final item in items) {
      final a = root.name.local == 'feed'
          ? _parseAtomEntry(item, sourceId, sourceName)
          : _parseRssItem(item, sourceId, sourceName);
      if (a != null) out.add(a);
    }
    return out;
  } catch (_) {
    return const [];
  }
}

Map<String, String> _directChildren(XmlElement e) {
  final map = <String, String>{};
  for (final child in e.childElements) {
    map.putIfAbsent(child.name.local, () => child.innerText.trim());
  }
  return map;
}

/// First image URL from media:content / media:thumbnail / enclosure.
String? _imageOf(XmlElement item) {
  for (final d in item.descendantElements) {
    final local = d.name.local;
    if (local == 'content' || local == 'thumbnail') {
      final url = d.getAttribute('url')?.trim();
      if (url != null && url.isNotEmpty) return url;
    } else if (local == 'enclosure') {
      final type = d.getAttribute('type') ?? '';
      if (type.startsWith('image/')) {
        final url = d.getAttribute('url')?.trim();
        if (url != null && url.isNotEmpty) return url;
      }
    }
  }
  return null;
}

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

DateTime? _parseDate(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final s = raw.trim();
  // ISO 8601 (Atom feeds).
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso.toUtc();
  // RFC 822 with numeric offset: "Mon, 19 Oct 2026 07:00:00 +0000".
  final m = RegExp(
          r'^\w{3},\s+(\d{1,2})\s+(\w{3})\s+(\d{4})\s+'
          r'(\d{2}):(\d{2})(?::(\d{2}))?\s+([+-])(\d{2})(\d{2})$')
      .firstMatch(s);
  if (m != null) {
    try {
      final month = _months[m.group(2)!.toLowerCase()];
      if (month == null) return null;
      final sign = m.group(7) == '+' ? 1 : -1;
      return DateTime.utc(
        int.parse(m.group(3)!),
        month,
        int.parse(m.group(1)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
        int.parse(m.group(6) ?? '0'),
      ).subtract(Duration(
          hours: sign * int.parse(m.group(8)!),
          minutes: sign * int.parse(m.group(9)!)));
    } catch (_) {
      return null;
    }
  }
  return null;
}

NewsArticle? _parseRssItem(
    XmlElement item, String sourceId, String sourceName) {
  final f = _directChildren(item);
  final title = (f['title'] ?? '').trim();
  final link = (f['link'] ?? '').trim();
  if (title.isEmpty || link.isEmpty) return null;
  var summary = f['description'];
  if (summary != null) {
    summary = _stripHtml(summary).trim();
    if (summary.length > 220) summary = '${summary.substring(0, 220)}…';
    if (summary.isEmpty) summary = null;
  }
  return NewsArticle(
    title: title,
    link: link,
    sourceId: sourceId,
    sourceName: sourceName,
    publishedAt: _parseDate(f['pubDate'] ?? f['date']),
    imageUrl: _imageOf(item),
    summary: summary,
  );
}

NewsArticle? _parseAtomEntry(
    XmlElement entry, String sourceId, String sourceName) {
  String title = '';
  String link = '';
  String? date;
  String? summary;
  for (final child in entry.childElements) {
    switch (child.name.local) {
      case 'title':
        title = child.innerText.trim();
      case 'link':
        final rel = child.getAttribute('rel');
        if ((rel == null || rel == 'alternate') && link.isEmpty) {
          link = child.getAttribute('href')?.trim() ?? '';
        }
      case 'published':
        date ??= child.innerText.trim();
      case 'updated':
        date ??= child.innerText.trim();
      case 'summary':
        summary = child.innerText.trim();
    }
  }
  if (title.isEmpty || link.isEmpty) return null;
  if (summary != null) {
    summary = _stripHtml(summary).trim();
    if (summary.length > 220) summary = '${summary.substring(0, 220)}…';
    if (summary.isEmpty) summary = null;
  }
  return NewsArticle(
    title: title,
    link: link,
    sourceId: sourceId,
    sourceName: sourceName,
    publishedAt: _parseDate(date),
    imageUrl: _imageOf(entry),
    summary: summary,
  );
}

String _stripHtml(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    // Tags replaced by spaces leave a space before punctuation
    // ("road</b>." -> "road ."); drop it.
    .replaceAllMapped(
        RegExp(r'\s+([.,;:!?])'), (m) => m.group(1)!);
