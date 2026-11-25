enum OutdoorNoticeStatus {
  eligible,
  belowThreshold,
  missing,
  stale,
  unavailable,
}

class OutdoorNotice {
  const OutdoorNotice(this.status,
      {this.date, this.chance, this.fetchedAt, this.validUntil});

  factory OutdoorNotice.fromJson(Map<String, dynamic> json, int cityId) {
    final status = switch (json['status']) {
      'eligible' => OutdoorNoticeStatus.eligible,
      'below_threshold' => OutdoorNoticeStatus.belowThreshold,
      'missing' => OutdoorNoticeStatus.missing,
      'stale' => OutdoorNoticeStatus.stale,
      _ => OutdoorNoticeStatus.unavailable,
    };
    if (status != OutdoorNoticeStatus.eligible &&
        status != OutdoorNoticeStatus.belowThreshold) {
      return OutdoorNotice(status);
    }
    final day = json['date'];
    final chance = json['precipitation_pct'];
    DateTime? instant(Object? value) =>
        value is String ? DateTime.tryParse(value) : null;
    final fetched = instant(json['fetched_at']);
    final expires = instant(json['valid_until']);
    if (json['city_id'] != cityId ||
        json['source'] != 'Open-Meteo' ||
        day is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day) ||
        DateTime.tryParse(day)?.toIso8601String().split('T').first != day ||
        chance is! num ||
        !chance.isFinite ||
        chance < 0 ||
        chance > 100 ||
        (chance >= 60) != (status == OutdoorNoticeStatus.eligible) ||
        fetched == null ||
        !fetched.isUtc ||
        expires == null ||
        !expires.isUtc ||
        !expires.isAfter(fetched)) {
      return const OutdoorNotice(OutdoorNoticeStatus.unavailable);
    }
    return OutdoorNotice(status,
        date: day, chance: chance, fetchedAt: fetched, validUntil: expires);
  }

  final OutdoorNoticeStatus status;
  final String? date;
  final num? chance;
  final DateTime? fetchedAt;
  final DateTime? validUntil;

  OutdoorNoticeStatus statusAt(DateTime now) {
    if (status != OutdoorNoticeStatus.eligible &&
        status != OutdoorNoticeStatus.belowThreshold) {
      return status;
    }
    return fetchedAt == null ||
            validUntil == null ||
            now.isBefore(fetchedAt!) ||
            !now.isBefore(validUntil!)
        ? OutdoorNoticeStatus.stale
        : status;
  }
}
