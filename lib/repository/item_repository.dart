import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:collection/collection.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:sprintf/sprintf.dart';
import 'package:sweet/bloc/item_repository_bloc/market_group_filters.dart';
import 'package:sweet/model/fitting/fitting_nanocore.dart';
import 'package:sweet/model/fitting/fitting_rig_integrator.dart';
import 'package:sweet/model/nihilus_space_modifier.dart';
import 'package:sweet/model/ship/ship_fitting_slot_module.dart';

import '../extensions/item_meta_extension.dart';

import '../bloc/data_loading_bloc/data_loading.dart';

import '../util/constants.dart';
import '../util/platform_helper.dart';

import '../database/database_exports.dart';
import '../database/database_mobile.dart';
import '../database/entities/entities.dart' as eve;

import '../model/character/learned_skill.dart';

import '../model/fitting/fitting.dart';
import '../model/fitting/fitting_drone.dart';
import '../model/fitting/fitting_item.dart';
import '../model/fitting/fitting_module.dart';
import '../model/fitting/fitting_ship.dart';
import '../model/fitting/fitting_skill.dart';

import '../model/items/eve_echoes_categories.dart';

import '../model/ship/eve_echoes_attribute.dart';
import '../model/ship/ship_loadout_definition.dart';
import '../model/ship/module_state.dart';
import '../model/ship/ship_fitting_loadout.dart';
import '../model/ship/slot_type.dart';

import '../service/fitting_simulator.dart';
import '../service/attribute_calculator_service.dart';

import '../util/crc32.dart' as crc;

part 'item_repository_fitting.dart';
part 'item_repository_db_functions.dart';

typedef DownloadProgressCallback = void Function(int, int);

class ItemRepository {
  Map<int, MarketGroup> marketGroupMap = {};
  List<int> _excludeFusionRigs = [];
  List<int> get excludeFusionRigs => _excludeFusionRigs;

  final Map<int, Item> _itemsCache = {};
  final Map<int, Attribute> _attributeCache = {};

  int get skillItemsCount => fittingSkills.values.length;

  final EveEchoesDatabase _echoesDatabase = EveEchoesDatabase();
  String _currentLanguageCode = 'en';
  EveEchoesDatabase get db => _echoesDatabase;
  Map<int, FittingSkill> fittingSkills = {};

  Future<bool> checkForDatabaseUpdate({
    required int latestVersion,
    required bool checkEtag,
    required int dbCrc,
    bool performCrcCheck = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final dbVersion = prefs.getInt('dbVersion');
    final dbIsOK = await dbOK(
      checkEtag: checkEtag,
      dbCrc: dbCrc,
      performCrcCheck: performCrcCheck,
    );
    return dbVersion == null || dbVersion != latestVersion || !dbIsOK;
  }

  Future<bool> dbOK({
    required bool checkEtag,
    required int dbCrc,
    required bool performCrcCheck,
  }) async {
    final dbFile = await PlatformHelper.dbFile();
    final isOK = await dbFile.exists();

    if (!isOK) return false;

    if (checkEtag) {
      final dbUrl = Uri.parse(kDBUrl);
      final response = await http.Client().send(http.Request('HEAD', dbUrl));
      final dbEtag = response.headers['etag'];

      if (response.statusCode >= 400) {
        throw Exception('Invalid Status code: ${response.statusCode}');
      }

      final prefs = await SharedPreferences.getInstance();
      final storedEtag = prefs.getString('dbEtag');

      if (dbEtag == null) {
        throw Exception(
            'ETag is missing: \n ${response.headers.keys.join(', ')}');
      }

      if (storedEtag != dbEtag) return false;
    }

    if (performCrcCheck) {
      final crc32 = await databaseCrc();
      return crc32 == dbCrc;
    }

    return true;
  }

  Future<int> databaseCrc() async {
    final dbFile = await PlatformHelper.dbFile();

    final isOK = await dbFile.exists();

    if (!isOK) {
      throw Exception('Database is missing');
    }

    final bytes = await dbFile.readAsBytes();
    final crc32 = await compute(calculateCrc, bytes);
    return crc32;
  }

  Future<void> downloadDatabase({
    required int latestVersion,
    required bool useNewDbLocation,
    required Emitter<DataLoadingBlocState> emitter,
  }) async {
    final dbFile = await PlatformHelper.dbFile();
    final prefs = await SharedPreferences.getInstance();

    // Download the latest DB
    print('Downloading DB...');
    emitter(LoadingRepositoryState('Downloading DB for v$latestVersion...'));
    final dbUrlString = sprintf(kDBUrlFormat, [latestVersion]);
    final dbTestUrl = Uri.parse(useNewDbLocation ? kDBUrl : dbUrlString);
    print('Downloading DB from $dbTestUrl');

    var response = await http.Client().send(http.Request('GET', dbTestUrl));
    var totalBytes = response.contentLength;
    var downloadedBytes = 0;
    var bytes = <int>[];

    if (response.statusCode >= 400) {
      throw Exception('Invalid Status code: ${response.statusCode}');
    }

    var stream = response.stream;

    await for (var value in stream) {
      bytes.addAll(value);
      downloadedBytes += value.length;
      emitter(DownloadingDatabaseState(
        downloadedBytes: downloadedBytes,
        totalBytes: totalBytes!,
        message:
            'Downloading Database\n${filesize(downloadedBytes, 2)} of ${filesize(totalBytes, 2)}',
      ));
    }

    emitter(LoadingRepositoryState('Decompressing DB...'));
    await compute(decompressDbArchive, bytes).then((tarData) {
      print('Writing DB to ${dbFile.path}');
      return dbFile.writeAsBytes(tarData, flush: true);
    }).then((writtenFile) {
      print('Written DB to ${writtenFile.path}');

      final dbEtag = response.headers['etag'];
      if (dbEtag == null) return Future.value(true);
      return prefs.setString('dbEtag', dbEtag);
    });
  }

  Future<void> openDatabase() async {
    final dbFile = await PlatformHelper.dbFile();

    if (!dbFile.existsSync()) {
      throw Exception('DB missing at ${dbFile.path}');
    }

    await _echoesDatabase.openDatabase(path: dbFile.absolute.path);

    fittingSkills = {
      for (var s in await fittingSkillsFromDbSkills()) s.itemId: s
    };

    unawaited(nSpaceModifiers().then((value) => nSpaceMods = value));

    final prefs = await SharedPreferences.getInstance();
    final dbVersion = await _echoesDatabase.getVersion();
    final savedDbVersion = prefs.getInt('dbVersion');
    if (savedDbVersion != dbVersion) {
      await prefs.setInt('dbVersion', dbVersion);
    }
  }

  var nSpaceMods = <NihilusSpaceModifier>[];

  bool setCurrentLanguage(String langCode) {
    _currentLanguageCode = langCode;

    return true;
  }

  Future<void> processMarketGroups() async {
    var mkgs = await _echoesDatabase.marketGroupDao.selectAll();
    marketGroupMap = {for (var m in mkgs) m.id: m};
    for (var mkg in marketGroupMap.values) {
      var items = await itemsForMarketGroup(marketGroupId: mkg.id);
      if (items.isNotEmpty) {
        mkg.items = items.toList();
      }

      if (mkg.parentId != null) {
        marketGroupMap[mkg.parentId!]!.children.add(mkg);
      }
    }
  }

  Future<void> processExcludeFusionRigs() async {
    // There are rigs (at the time of writing only the higgs anchors), that
    // can't be integrated and have to get filtered out of the fitting menu for
    // integrated rigs.
    _excludeFusionRigs = [for (var id in await getExcludeFusionRigs()) id];
  }

  Future<Iterable<FittingSkill>> fittingSkillsFromDbSkills() async {
    final skills = await skillItems;

    final ids = skills.map((e) => e.id);
    final items = {for (var item in await skillItems) item.id: item};

    // Get all the attributes
    final itemAttributes = await getBaseAttributesForItemIds(ids);

    // Get all the modifiers
    final modifiers = await getModifiersForSkillIds(ids);

    return ids.map(
      (e) => FittingSkill(
        item: items[e]!, // Safe as the items are known
        baseAttributes: itemAttributes[e]?.toList() ?? [],
        modifiers: modifiers[e]?.toList() ?? [],
        skillLevel: 5,
      ),
    );
  }
}

List<int> decompressDbArchive(List<int> bytes) {
  print('Decompressing DB...');
  final bzipData = BZip2Decoder().decodeBytes(bytes);
  print('Decoding DB Tar ...');
  final tarData = TarDecoder().decodeBytes(bzipData);
  return tarData.files.firstOrNull?.content ?? [];
}

int calculateCrc(List<int> bytes) {
  return crc.CRC32.compute(bytes).toSigned(32);
}
