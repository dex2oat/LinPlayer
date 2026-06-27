import 'package:flutter_test/flutter_test.dart';
import 'package:linplayer_mobile/core/utils/library_filter_utils.dart';

void main() {
  test('buildYearChips: 当前十年逐年 + 更早按年代分桶', () {
    final chips = buildYearChips(
      ['2026', '2024', '2020', '2019', '2008', '1995', 'bad', '0'],
      currentYear: 2026,
    );
    final labels = chips.map((c) => c.label).toList();
    expect(labels, ['2026', '2024', '2020', '10年代', '00年代', '90年代']);

    // 逐年项 csv 即自身
    expect(chips.firstWhere((c) => c.label == '2024').yearsCsv, '2024');
    // 年代项展开为该十年的全部年份
    expect(chips.firstWhere((c) => c.label == '10年代').yearsCsv,
        '2010,2011,2012,2013,2014,2015,2016,2017,2018,2019');
    expect(chips.firstWhere((c) => c.label == '00年代').yearsCsv.split(',').first,
        '2000');
  });

  test('LibraryFilterValue: 单选切换与激活计数', () {
    const v0 = LibraryFilterValue();
    expect(v0.isEmpty, true);
    expect(v0.activeCount, 0);

    final v1 = v0.withGenre('喜剧').withStudio('正午阳光').withYear('2024', '2024');
    expect(v1.activeCount, 3);
    expect(v1.isEmpty, false);

    // 取消年份，其余保留（哨兵区分"不改"与"置空"）
    final v2 = v1.withYear(null, null);
    expect(v2.activeCount, 2);
    expect(v2.genre, '喜剧');
    expect(v2.studio, '正午阳光');

    expect(v1,
        v0.withGenre('喜剧').withStudio('正午阳光').withYear('2024', '2024')); // 值相等
  });
}
