import 'package:flutter/widgets.dart';

import '../models/plate_record.dart';
import '../models/plate_area.dart';

/// Every text the scanner shows. English and Amharic are built in; a host
/// app passes its own (any language) or changes a few with [copyWith].
///
/// When none is given, [PlateScannerStrings.of] picks Amharic for an `am`
/// locale and English otherwise.
@immutable
class PlateScannerStrings {
  /// Creates a full set of strings.
  const PlateScannerStrings({
    required this.fitPlate,
    required this.plateFound,
    required this.capture,
    required this.confirmAreaHint,
    required this.retake,
    required this.confirmArea,
    required this.reading,
    required this.done,
    required this.edit,
    required this.adjustArea,
    required this.plateRead,
    required this.sectionCode,
    required this.sectionGeezRegion,
    required this.sectionNumber,
    required this.sectionRegion,
    required this.fieldCode,
    required this.fieldRegion,
    required this.fieldSerial,
    required this.issueMissingCode,
    required this.issueUnknownCode,
    required this.issueMissingRegion,
    required this.issueMissingSerial,
    required this.somethingWentWrong,
    required this.tryAgain,
    required this.permissionTitle,
    required this.permissionMessage,
    required this.openSettings,
    required this.unsupportedDevice,
    required this.close,
    required this.torch,
    required this.save,
    required this.patrolHint,
    required this.finish,
    required this.platesRead,
    required this.check,
  });

  /// English.
  const PlateScannerStrings.en()
      : fitPlate = 'Fit the plate inside the frame',
        plateFound = 'Hold steady',
        capture = 'Capture',
        confirmAreaHint = 'Is the whole plate inside the box?\n'
            'Drag the box or its corners to adjust.',
        retake = 'Retake',
        confirmArea = 'Confirm area',
        reading = 'Reading plate…',
        done = 'Done',
        edit = 'Edit',
        adjustArea = 'Adjust area',
        plateRead = 'Plate read',
        sectionCode = 'Code',
        sectionGeezRegion = "Region (Ge'ez)",
        sectionNumber = 'Number',
        sectionRegion = 'Region',
        fieldCode = 'Code',
        fieldRegion = 'Region',
        fieldSerial = 'Serial',
        issueMissingCode = 'Code not read',
        issueUnknownCode = 'Unknown code',
        issueMissingRegion = 'Region not read',
        issueMissingSerial = 'Number not read',
        somethingWentWrong = 'Something went wrong',
        tryAgain = 'Try again',
        permissionTitle = 'Camera access needed',
        permissionMessage =
            'Allow camera access in Settings to scan licence plates.',
        openSettings = 'Open settings',
        unsupportedDevice = 'This device cannot read plates.',
        close = 'Close',
        torch = 'Torch',
        save = 'Save',
        patrolHint = 'Move past the vehicles — plates are read automatically',
        finish = 'Finish',
        platesRead = 'plates',
        check = 'Check';

  /// Amharic.
  const PlateScannerStrings.am()
      : fitPlate = 'ታርጋውን በማዕቀፉ ውስጥ ያስገቡ',
        plateFound = 'ሳያንቀሳቅሱ ይያዙ',
        capture = 'አንሳ',
        confirmAreaHint = 'ታርጋው በሙሉ በሳጥኑ ውስጥ ነው?\n'
            'ለማስተካከል ሳጥኑን ወይም ጠርዞቹን ይጎትቱ።',
        retake = 'እንደገና አንሳ',
        confirmArea = 'አረጋግጥ',
        reading = 'ታርጋውን በማንበብ ላይ…',
        done = 'ጨርስ',
        edit = 'አስተካክል',
        adjustArea = 'ቦታውን አስተካክል',
        plateRead = 'ታርጋው ተነቧል',
        sectionCode = 'ኮድ',
        sectionGeezRegion = 'ክልል (ግዕዝ)',
        sectionNumber = 'ቁጥር',
        sectionRegion = 'ክልል',
        fieldCode = 'ኮድ',
        fieldRegion = 'ክልል',
        fieldSerial = 'ቁጥር',
        issueMissingCode = 'ኮዱ አልተነበበም',
        issueUnknownCode = 'ያልታወቀ ኮድ',
        issueMissingRegion = 'ክልሉ አልተነበበም',
        issueMissingSerial = 'ቁጥሩ አልተነበበም',
        somethingWentWrong = 'የሆነ ችግር ተፈጥሯል',
        tryAgain = 'እንደገና ሞክር',
        permissionTitle = 'የካሜራ ፈቃድ ያስፈልጋል',
        permissionMessage = 'ታርጋ ለማንበብ በቅንብሮች ውስጥ የካሜራ ፈቃድ ይስጡ።',
        openSettings = 'ቅንብሮችን ክፈት',
        unsupportedDevice = 'ይህ መሣሪያ ታርጋ ማንበብ አይችልም።',
        close = 'ዝጋ',
        torch = 'የእጅ ባትሪ',
        save = 'አስቀምጥ',
        patrolHint = 'በተሽከርካሪዎቹ አጠገብ ይለፉ — ታርጋዎቹ በራሳቸው ይነበባሉ',
        finish = 'ጨርስ',
        platesRead = 'ታርጋዎች',
        check = 'ያረጋግጡ';

  /// Built-in strings for [locale]: Amharic for `am`, else English.
  factory PlateScannerStrings.forLocale(Locale? locale) =>
      locale?.languageCode == 'am'
          ? const PlateScannerStrings.am()
          : const PlateScannerStrings.en();

  /// Built-in strings for the app's current locale.
  static PlateScannerStrings of(BuildContext context) =>
      PlateScannerStrings.forLocale(Localizations.maybeLocaleOf(context));

  /// Step 1: hint before / after a plate is found, and the capture button.
  final String fitPlate, plateFound, capture;

  /// Step 2: confirm the plate area.
  final String confirmAreaHint, retake, confirmArea;

  /// Step 3: while reading.
  final String reading;

  /// Step 4: review.
  final String done, edit, adjustArea, plateRead;

  /// Section labels in review.
  final String sectionCode, sectionGeezRegion, sectionNumber, sectionRegion;

  /// Field labels when editing.
  final String fieldCode, fieldRegion, fieldSerial;

  /// Validation problems.
  final String issueMissingCode,
      issueUnknownCode,
      issueMissingRegion,
      issueMissingSerial;

  /// Errors.
  final String somethingWentWrong, tryAgain;

  /// Camera permission denied.
  final String permissionTitle, permissionMessage, openSettings;

  /// Device without plate reading.
  final String unsupportedDevice;

  /// Button labels for screen readers.
  final String close, torch;

  /// Closes the edit form.
  final String save;

  /// Patrol: the hint before any plate, the button that ends it, the label
  /// after the count ("12 plates"), and the mark on an uncertain reading.
  final String patrolHint, finish, platesRead, check;

  /// Text for [issue].
  String issue(PlateIssue issue) => switch (issue) {
        PlateIssue.missingCode => issueMissingCode,
        PlateIssue.unknownCode => issueUnknownCode,
        PlateIssue.missingRegion => issueMissingRegion,
        PlateIssue.missingSerial => issueMissingSerial,
      };

  /// Label for a plate section.
  String section(PlateSectionKind kind) => switch (kind) {
        PlateSectionKind.code => sectionCode,
        PlateSectionKind.geezRegion => sectionGeezRegion,
        PlateSectionKind.number => sectionNumber,
        PlateSectionKind.latinRegion => sectionRegion,
      };

  /// A copy with the given strings replaced.
  PlateScannerStrings copyWith({
    String? fitPlate,
    String? plateFound,
    String? capture,
    String? confirmAreaHint,
    String? retake,
    String? confirmArea,
    String? reading,
    String? done,
    String? edit,
    String? adjustArea,
    String? plateRead,
    String? sectionCode,
    String? sectionGeezRegion,
    String? sectionNumber,
    String? sectionRegion,
    String? fieldCode,
    String? fieldRegion,
    String? fieldSerial,
    String? issueMissingCode,
    String? issueUnknownCode,
    String? issueMissingRegion,
    String? issueMissingSerial,
    String? somethingWentWrong,
    String? tryAgain,
    String? permissionTitle,
    String? permissionMessage,
    String? openSettings,
    String? unsupportedDevice,
    String? close,
    String? torch,
    String? save,
    String? patrolHint,
    String? finish,
    String? platesRead,
    String? check,
  }) =>
      PlateScannerStrings(
        fitPlate: fitPlate ?? this.fitPlate,
        plateFound: plateFound ?? this.plateFound,
        capture: capture ?? this.capture,
        confirmAreaHint: confirmAreaHint ?? this.confirmAreaHint,
        retake: retake ?? this.retake,
        confirmArea: confirmArea ?? this.confirmArea,
        reading: reading ?? this.reading,
        done: done ?? this.done,
        edit: edit ?? this.edit,
        adjustArea: adjustArea ?? this.adjustArea,
        plateRead: plateRead ?? this.plateRead,
        sectionCode: sectionCode ?? this.sectionCode,
        sectionGeezRegion: sectionGeezRegion ?? this.sectionGeezRegion,
        sectionNumber: sectionNumber ?? this.sectionNumber,
        sectionRegion: sectionRegion ?? this.sectionRegion,
        fieldCode: fieldCode ?? this.fieldCode,
        fieldRegion: fieldRegion ?? this.fieldRegion,
        fieldSerial: fieldSerial ?? this.fieldSerial,
        issueMissingCode: issueMissingCode ?? this.issueMissingCode,
        issueUnknownCode: issueUnknownCode ?? this.issueUnknownCode,
        issueMissingRegion: issueMissingRegion ?? this.issueMissingRegion,
        issueMissingSerial: issueMissingSerial ?? this.issueMissingSerial,
        somethingWentWrong: somethingWentWrong ?? this.somethingWentWrong,
        tryAgain: tryAgain ?? this.tryAgain,
        permissionTitle: permissionTitle ?? this.permissionTitle,
        permissionMessage: permissionMessage ?? this.permissionMessage,
        openSettings: openSettings ?? this.openSettings,
        unsupportedDevice: unsupportedDevice ?? this.unsupportedDevice,
        close: close ?? this.close,
        torch: torch ?? this.torch,
        save: save ?? this.save,
        patrolHint: patrolHint ?? this.patrolHint,
        finish: finish ?? this.finish,
        platesRead: platesRead ?? this.platesRead,
        check: check ?? this.check,
      );
}
