import 'dart:math';

const int kMaxNurfSequenceLength = 8;
final List<double> kNurfDenominators = List.generate(kMaxNurfSequenceLength,
    (idx) => pow((pi / 2 - 1), pow((idx / 2.0), 2)) as double);

abstract class StringFormats {
  static const twoDecimalPlaces = '#,##0.00';
}

const kNanocoreWeights = [5, 5, 5, 4, 4, 4, 3, 3, 2, 2, 1];

const kSkillLevelBase = [
  250.00,
  1415.00,
  8000.00,
  45255.00,
  256000.00,
];
const kMaxSkillLevel = 5;

int skillSPForLevel({
  required double skillExp,
  required int skillLevel,
}) =>
    skillLevel > kMaxSkillLevel || skillLevel <= 0
        ? 0
        : ((skillExp * kSkillLevelBase[skillLevel - 1]) / 1000).ceil();

const kSec = 1000.0;
const kMinute = 60 * kSec;
const kHour = 60 * 60 * kSec;
const kCapStableTime = kHour;

const kGroupRepairersHealSelf = true;

const kEEVersionManUpKey = 'echoes_version';
const kDbCrcManUpKey = 'db_crc';
const kUseNewDbLocation = 'use_new_db';
const kPerformCrcManUpKey = 'perform_crc_check';
const kPatchDayManUpKey = 'patch_day';
const kPatchHourManUpKey = 'patch_hour';
const kPatchMinuteManUpKey = 'patch_minute';

const kManUpUrl = 'https://sillykat.page.link/sweet-manup-s3';
const kDBUrl = 'https://sillykat.page.link/sweet-db';

const kDBUrlFormat =
    'https://firebasestorage.googleapis.com/v0/b/eve-echoes-tool-5474b.appspot.com/o/game_data%%2Fechoes_%d.tbz?alt=media&token=2cf07c7e-8883-46fa-97f4-63dc10b15087';

const kNihilusCapAdjustmentModifierTypeCode = '/Nihilus/ChargeDe/';
