// News source registry (FR-20): 9 bundled publications, all RSS verified
// 2026-10-18. Each is toggleable; toggles persist in Hive (see
// NewsRepository). A failing source is isolated per-fetch and never breaks
// the tab; the source manager shows a subtle "unavailable" note.

class NewsSource {
  final String id;
  final String name;
  final String feedUrl;

  const NewsSource({
    required this.id,
    required this.name,
    required this.feedUrl,
  });
}

const List<NewsSource> newsSources = [
  NewsSource(
      id: 'pitchfork',
      name: 'Pitchfork',
      feedUrl: 'https://pitchfork.com/feed/rss/'),
  NewsSource(
      id: 'nme', name: 'NME', feedUrl: 'https://www.nme.com/feed'),
  NewsSource(
      id: 'rollingstone',
      name: 'Rolling Stone',
      feedUrl: 'https://www.rollingstone.com/feed/'),
  NewsSource(
      id: 'billboard',
      name: 'Billboard',
      feedUrl: 'https://www.billboard.com/feed/'),
  NewsSource(
      id: 'consequence',
      name: 'Consequence',
      feedUrl: 'https://consequence.net/feed/'),
  NewsSource(
      id: 'stereogum',
      name: 'Stereogum',
      feedUrl: 'https://www.stereogum.com/feed/'),
  NewsSource(
      id: 'mbw',
      name: 'Music Business Worldwide',
      feedUrl: 'https://www.musicbusinessworldwide.com/feed/'),
  NewsSource(id: 'edm', name: 'EDM.com', feedUrl: 'https://edm.com/feed'),
  NewsSource(
      id: 'jrocknews',
      name: 'JROCK NEWS',
      feedUrl: 'https://jrocknews.com/feed'),
];
