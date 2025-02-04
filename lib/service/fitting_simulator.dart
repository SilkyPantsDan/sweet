import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sweet/extensions/item_modifier_ui_extension.dart';
import 'package:sweet/model/fitting/fitting_nanocore.dart';
import 'package:sweet/model/fitting/fitting_rig_integrator.dart';
import 'package:sweet/model/items/eve_echoes_categories.dart';
import 'package:sweet/model/nihilus_space_modifier.dart';
import 'package:sweet/model/ship/ship_loadout_definition.dart';

import '../database/database_exports.dart';
import '../model/character/character.dart';
import '../model/character/learned_skill.dart';
import '../model/fitting/fitting.dart';
import '../model/fitting/fitting_drone.dart';
import '../model/fitting/fitting_item.dart';
import '../model/fitting/fitting_module.dart';
import '../model/fitting/fitting_patterns.dart';
import '../model/fitting/fitting_ship.dart';
import '../model/fitting/fitting_skill.dart';
import '../model/ship/capacitor_simulation_results.dart';
import '../model/ship/eve_echoes_attribute.dart';
import '../model/ship/module_state.dart';
import '../model/ship/ship_fitting_loadout.dart';
import '../model/ship/slot_type.dart';
import '../model/ship/weapon_type.dart';
import '../repository/item_repository.dart';
import '../repository/localisation_repository.dart';
import '../util/constants.dart';
import 'attribute_calculator_service.dart';
import 'capacitor_simulator.dart';

class FittingSimulator extends ChangeNotifier {
  static late FittingItem _characterItem;
  static late FittingPatterns fittingPatterns;

  static FittingPattern? _currentDamagePattern;
  FittingPattern get currentDamagePattern =>
      _currentDamagePattern ?? FittingPattern.uniform;

  set currentDamagePattern(FittingPattern newPattern) {
    _currentDamagePattern = newPattern;
    notifyListeners();
  }

  final FittingShip ship;
  final CapacitorSimulator capacitorSimulator;
  final ItemRepository _itemRepository;
  final AttributeCalculatorService _attributeCalculatorService;

  final Fitting _fitting;

  Iterable<FittingModule> modules({required SlotType slotType}) =>
      _fitting[slotType] ?? [];

  String get name => loadout.name;
  void setName(String newName) {
    loadout.setName(newName);
    notifyListeners();
  }

  Character? _pilot;
  Character get pilot => _pilot ?? Character.empty;
  void setPilot(Character newPilot) {
    _pilot?.removeListener(_pilotListener);
    _pilot = newPilot;
    _pilot?.addListener(_pilotListener);
    _pilotListener();
  }

  void _pilotListener() {
    updateSkills(skills: pilot.learntSkills).then(
      (_) => notifyListeners(),
    );
  }

  final ShipFittingLoadout loadout;
  String generateQrCodeData() => loadout.generateQrCodeData();

  static void loadDefinitions(
    ItemRepository itemRepository,
  ) {
    rootBundle.loadString('assets/fitting-patterns.json').then(
          (jsonString) =>
              fittingPatterns = FittingPatterns.fromRawJson(jsonString),
        );

    itemRepository
        .loadFittingCharacter()
        .then((value) => _characterItem = value);
  }

  FittingSimulator._create({
    required ItemRepository itemRepository,
    required AttributeCalculatorService attributeCalculatorService,
    required this.ship,
    required this.loadout,
    required Fitting fitting,
    Character? pilot,
  })  : _fitting = fitting,
        _itemRepository = itemRepository,
        _attributeCalculatorService = attributeCalculatorService,
        capacitorSimulator = CapacitorSimulator(
          attributeCalculatorService: attributeCalculatorService,
          ship: ship,
        ) {
    if (pilot != null) {
      setPilot(pilot);
    }
  }

  static Future<FittingSimulator> fromShipLoadout({
    required FittingShip ship,
    required ShipFittingLoadout loadout,
    required ItemRepository itemRepository,
    required AttributeCalculatorService attributeCalculatorService,
    required Character pilot,
  }) async =>
      FittingSimulator._create(
        attributeCalculatorService: attributeCalculatorService,
        itemRepository: itemRepository,
        ship: ship,
        loadout: loadout,
        pilot: pilot,
        fitting: await itemRepository.fittingDataFromLoadout(
          loadout: loadout,
          attributeCalculatorService: attributeCalculatorService,
        ),
      );

  static Future<FittingSimulator> fromDrone(
    FittingShip droneShip, {
    required ShipFittingLoadout loadout,
    required ItemRepository itemRepository,
    required AttributeCalculatorService attributeCalculatorService,
  }) async {
    return FittingSimulator._create(
      ship: droneShip,
      attributeCalculatorService: attributeCalculatorService,
      itemRepository: itemRepository,
      loadout: loadout,
      fitting: await itemRepository.fittingDataFromLoadout(
        loadout: loadout,
        attributeCalculatorService: attributeCalculatorService,
      ),
    );
  }

  ///
  ///
  ///
  Duration warpPreparationTime() {
    final mass = getValueForShip(attribute: EveEchoesAttribute.mass);
    final agility =
        getValueForShip(attribute: EveEchoesAttribute.interiaModifier);

    return Duration(
        milliseconds: ((-mass * agility / 1000000 * log(0.2)) * 1000).toInt());
  }

  ///
  ///
  ///
  double maxFlightVelocity() {
    // Get from active AB/MWD
    final activeBoostModule = _fitting.allFittedModules
        .where((module) =>
            module.state != ModuleState.inactive &&
            module.groupId == EveEchoesGroup.propulsion.groupId)
        .firstOrNull;

    final maxVelocity =
        getValueForShip(attribute: EveEchoesAttribute.flightVelocity);

    if (activeBoostModule == null) {
      return maxVelocity;
    }

    final speedBoost = getValueForItem(
        item: activeBoostModule, attribute: EveEchoesAttribute.speedBoost);
    final speedBoostFactor = getValueForItem(
        item: activeBoostModule,
        attribute: EveEchoesAttribute.speedBoostFactor);

    final mass = getValueForShip(attribute: EveEchoesAttribute.mass);

    return (1 + speedBoost * speedBoostFactor / mass) * maxVelocity;
  }

  ///
  /// POWER GRID USAGE
  ///

  double calculatePowerGridUtilisation() {
    return getPowerGridUsage() / getPowerGridOutput();
  }

  double getPowerGridOutput() => getValueForShip(
        attribute: EveEchoesAttribute.powerGridOutput,
      );

  double getPowerGridUsage() {
    var pgCosts = _fitting.allFittedModules.map((item) {
      return getValueForItem(
        attribute: EveEchoesAttribute.powerGridRequirement,
        item: item,
      );
    });

    var totalPGCost = pgCosts.fold(0.0, (dynamic previousValue, pgRequirement) {
      return previousValue + pgRequirement;
    });

    return totalPGCost;
  }

  ///
  /// DEFENSE
  ///

  double calculateTotalEHPForDamagePattern(
    FittingPattern damagePattern,
  ) {
    return kDefenceAttributes.keys
        .map(
          (hpAttribute) => calculateEHPForAttribute(
              hpAttribute: hpAttribute, damagePattern: damagePattern),
        )
        .fold<double>(0, (previousValue, value) => previousValue + value);
  }

  double calculateEHPForAttribute({
    required EveEchoesAttribute hpAttribute,
    required FittingPattern damagePattern,
  }) {
    return _calculateEHPForValue(
      value: rawHPForAttribute(hpAttribute: hpAttribute),
      damagePattern: damagePattern,
      resonanceAttributes: kDefenceAttributes[hpAttribute]!,
    );
  }

  double _calculateEHPForValue({
    required double value,
    required FittingPattern damagePattern,
    required List<EveEchoesAttribute> resonanceAttributes,
  }) {
    final resonances = resonanceAttributes
        .map(
          (e) => getValueForItem(
            attribute: e,
            item: ship,
          ),
        )
        .toList();

    var weighted = (resonances[0] * damagePattern.emPercent) +
        (resonances[1] * damagePattern.thermalPercent) +
        (resonances[2] * damagePattern.kineticPercent) +
        (resonances[3] * damagePattern.explosivePercent);

    return value / weighted;
  }

  double calculateWeakestEHP() {
    // Get HP and resonances
    var values = kDefenceAttributes.entries.map((element) {
      var hpValue = getValueForItem(
        attribute: element.key,
        item: ship,
      );

      var resonances = element.value.map(
        (e) => getValueForItem(
          attribute: e,
          item: ship,
        ),
      );

      var maxResonance = resonances.reduce(max);
      return hpValue / maxResonance;
    });
    var res = values.fold(
        0, (dynamic previousValue, element) => previousValue + element);
    return res;
  }

  double rawHPForAttribute({
    required EveEchoesAttribute hpAttribute,
  }) =>
      getValueForItem(
        attribute: hpAttribute,
        item: ship,
      );

  double calculatePassiveShieldRate() {
    final shieldHp = rawHPForAttribute(
      hpAttribute: EveEchoesAttribute.shieldCapacity,
    );

    final shieldRechargeRate = rawHPForAttribute(
      hpAttribute: EveEchoesAttribute.shieldRechargeRate,
    );
    return (shieldHp / (shieldRechargeRate / kSec)) * 2.5;
  }

  double calculateEhpPassiveShieldRate({
    required FittingPattern damagePattern,
  }) {
    final shieldHp = calculateEHPForAttribute(
      hpAttribute: EveEchoesAttribute.shieldCapacity,
      damagePattern: damagePattern,
    );

    final shieldRechargeRate = rawHPForAttribute(
      hpAttribute: EveEchoesAttribute.shieldRechargeRate,
    );
    return (shieldHp / (shieldRechargeRate / kSec)) * 2.5;
  }

  double calculateRawShieldBoosterRate() => _fitting.allFittedModules
      .where((module) {
        return (module.slot == SlotType.mid || module.slot == SlotType.low) &&
            module.state == ModuleState.active &&
            module.baseAttributes.any((e) =>
                e.id == EveEchoesAttribute.shieldBoostAmount.attributeId);
      })
      .map(_calculateRawShieldBoosterRateForModule)
      .fold(0, (previousValue, next) => previousValue + next);

  double _calculateRawShieldBoosterRateForModule(FittingModule module) {
    final repairAmount = getValueForItem(
      attribute: EveEchoesAttribute.shieldBoostAmount,
      item: module,
    );
    final cycleTime = getValueForItem(
      attribute: EveEchoesAttribute.activationTime,
      item: module,
    );
    return repairAmount / (cycleTime / kSec);
  }

  double calculateEhpShieldBoosterRate({
    required FittingPattern damagePattern,
  }) =>
      _fitting.allFittedModules
          .where((module) {
            return (module.slot == SlotType.mid ||
                    module.slot == SlotType.low) &&
                module.state == ModuleState.active &&
                module.baseAttributes.any((e) =>
                    e.id == EveEchoesAttribute.shieldBoostAmount.attributeId);
          })
          .map(
            (e) => _calculateEhpShieldBoosterRateForModule(
              e,
              damagePattern: damagePattern,
            ),
          )
          .fold(0, (previousValue, next) => previousValue + next);

  double _calculateEhpShieldBoosterRateForModule(
    FittingModule module, {
    required FittingPattern damagePattern,
  }) {
    final repairAmount = _calculateEHPForValue(
      value: getValueForItem(
        attribute: EveEchoesAttribute.shieldBoostAmount,
        item: module,
      ),
      damagePattern: damagePattern,
      resonanceAttributes:
          kDefenceAttributes[EveEchoesAttribute.shieldCapacity]!,
    );
    final cycleTime = getValueForItem(
      attribute: EveEchoesAttribute.activationTime,
      item: module,
    );
    return repairAmount / (cycleTime / kSec);
  }

  double calculateRawArmorRepairRate() => _fitting.allFittedModules
      .where((module) {
        return (module.slot == SlotType.mid || module.slot == SlotType.low) &&
            module.state == ModuleState.active &&
            module.baseAttributes
                .any((e) => e.id == EveEchoesAttribute.armorRepair.attributeId);
      })
      .map(_calculateArmorRepairRateForModule)
      .fold(0, (previousValue, next) => previousValue + next);

  double _calculateArmorRepairRateForModule(FittingModule module) {
    final repairAmount = getValueForItem(
      attribute: EveEchoesAttribute.armorRepair,
      item: module,
    );
    final cycleTime = getValueForItem(
      attribute: EveEchoesAttribute.activationTime,
      item: module,
    );
    return repairAmount / (cycleTime / kSec);
  }

  double calculateEhpArmorRepairRate({
    required FittingPattern damagePattern,
  }) =>
      _fitting.allFittedModules
          .where((module) {
            return (module.slot == SlotType.mid ||
                    module.slot == SlotType.low) &&
                module.state == ModuleState.active &&
                module.baseAttributes.any(
                    (e) => e.id == EveEchoesAttribute.armorRepair.attributeId);
          })
          .map(
            (e) => _calculateEhpArmorRepairRateForModule(
              e,
              damagePattern: damagePattern,
            ),
          )
          .fold(0, (previousValue, next) => previousValue + next);

  double _calculateEhpArmorRepairRateForModule(
    FittingModule module, {
    required FittingPattern damagePattern,
  }) {
    final repairAmount = _calculateEHPForValue(
      value: getValueForItem(
        attribute: EveEchoesAttribute.armorRepair,
        item: module,
      ),
      damagePattern: damagePattern,
      resonanceAttributes: kDefenceAttributes[EveEchoesAttribute.armorHp]!,
    );
    final cycleTime = getValueForItem(
      attribute: EveEchoesAttribute.activationTime,
      item: module,
    );
    return repairAmount / (cycleTime / kSec);
  }

  ///
  /// MINING
  ///

  double calculateTotalMiningYeild() {
    return _fitting
        .fittedModulesForSlot(SlotType.high)
        .where((module) {
          return module.baseAttributes
              .any((e) => e.id == EveEchoesAttribute.miningAmount.attributeId);
        })
        .map(calculateMiningYeildForModule)
        .fold(0, (previousValue, next) => previousValue + next);
  }

  double calculateTotalMiningYeildPerMinute() {
    return _fitting
        .fittedModulesForSlot(SlotType.high)
        .where((module) {
          return module.baseAttributes
              .any((e) => e.id == EveEchoesAttribute.miningAmount.attributeId);
        })
        .map(calculateMiningYeildPerMinuteForModule)
        .fold(0, (previousValue, next) => previousValue + next);
  }

  Duration calculateMiningTimeToFill() {
    final ypmTurrents = calculateTotalMiningYeildPerMinute();
    final ypmDrones = calculateTotalMiningYeildPerMinuteForDrones();
    final ypm = ypmTurrents + ypmDrones;
    final holdSize = getValueForShip(
      attribute: EveEchoesAttribute.oreHoldCapacity,
    );

    return Duration(
      seconds: ((ypm > 0 ? holdSize / ypm : 0) * 60.0).toInt(),
    );
  }

  double calculateMiningYeildForModule(FittingModule module) => getValueForItem(
        attribute: EveEchoesAttribute.miningAmount,
        item: module,
      );

  double calculateMiningYeildPerMinuteForModule(FittingModule module) =>
      calculateMiningYeildForModule(module) /
      (getValueForItem(
            attribute: EveEchoesAttribute.activationTime,
            item: module,
          ) /
          kMinute);

  ///
  /// OFFENCE
  ///
  ///

  bool _isItemMissile(int id) {
    var groupId = id / Group.itemToGroupIdDivisor;
    return (groupId >= 11012 && groupId <= 11023) ||
        (groupId >= 24000 && groupId <= 24999);
  }

  bool _isItemTurret(int id) {
    var groupId = id / Group.itemToGroupIdDivisor;
    return (groupId >= 11000 && groupId <= 11005);
  }

  ///
  /// DPS
  ///

  double calculateTotalDps() {
    var highSlotDps = calculateTotalDpsForModules();
    var droneDps = calculateTotalDpsForDrones();

    return highSlotDps + droneDps;
  }

  double calculateTotalDpsForModules({WeaponType weaponType = WeaponType.all}) {
    if (weaponType == WeaponType.drone) {
      return calculateTotalDpsForDrones();
    }

    var modules = _fitting.fittedModulesForSlot(SlotType.high).where((module) {
      if (weaponType == WeaponType.turret) {
        return _isItemTurret(module.itemId);
      } else if (weaponType == WeaponType.missile) {
        return _isItemMissile(module.itemId);
      }
      return true;
    });

    return modules
        .map(
          (item) => calculateDpsForItem(
            item: item,
          ),
        )
        .fold<double>(
          0.0,
          (previousValue, itemDps) => previousValue + itemDps,
        );
  }

  double calculateDpsForItem({
    required FittingModule item,
  }) {
    final activationTimeDefinition = item.baseAttributes.firstWhereOrNull(
      (element) => element.id == EveEchoesAttribute.activationTime.attributeId,
    )!;
    var activationTime = getValueForItem(
      attribute: EveEchoesAttribute.activationTime,
      item: item,
    );

    activationTime =
        activationTimeDefinition.calculatedValue(fromValue: activationTime);

    return calculateAlphaStrikeForItem(item: item) / activationTime;
  }

  ///
  /// Alpha Strike
  ///

  double calculateTotalAlphaStrike() {
    var highSlotDps = calculateTotalAlphaStrikeForModules();
    var droneDps = calculateTotalAlphaStrikeForDrones();

    return highSlotDps + droneDps;
  }

  double calculateTotalAlphaStrikeForModules(
      {WeaponType weaponType = WeaponType.all}) {
    if (weaponType == WeaponType.drone) {
      return calculateTotalAlphaStrikeForDrones();
    }

    var modules = _fitting.fittedModulesForSlot(SlotType.high).where((module) {
      if (weaponType == WeaponType.turret) {
        return _isItemTurret(module.itemId);
      } else if (weaponType == WeaponType.missile) {
        return _isItemMissile(module.itemId);
      }
      return true;
    });

    return modules
        .map(
          (item) => calculateAlphaStrikeForItem(
            item: item,
          ),
        )
        .fold<double>(
          0.0,
          (previousValue, itemDps) => previousValue + itemDps,
        );
  }

  double calculateAlphaStrikeForItem({
    required FittingModule item,
  }) {
    if (item.state == ModuleState.inactive) return 0;
    // EM damage
    var emDamage = getValueForItem(
      attribute: EveEchoesAttribute.emDamage,
      item: item,
    );

    // Thermal damage
    var thermDamage = getValueForItem(
      attribute: EveEchoesAttribute.thermalDamage,
      item: item,
    );

    // Kinetic damage
    var kinDamage = getValueForItem(
      attribute: EveEchoesAttribute.kineticDamage,
      item: item,
    );

    // Explosive damage
    var expDamage = getValueForItem(
      attribute: EveEchoesAttribute.explosiveDamage,
      item: item,
    );

    return (emDamage + thermDamage + kinDamage + expDamage);
  }

  ///
  /// DRONES
  ///

  double calculateTotalDpsForDrones() {
    final moduleSlots = [
      SlotType.drone,
      SlotType.lightDDSlot,
      SlotType.lightFFSlot,
    ];
    return moduleSlots
        .map(_fitting.fittedModulesForSlot)
        .expand((e) => e)
        .where((d) => d.state != ModuleState.inactive)
        .map(
          (drone) => calculateDpsForDrone(
            drone: drone as FittingDrone,
          ),
        )
        .fold<double>(0.0, (previousValue, itemDps) => previousValue + itemDps);
  }

  double calculateTotalAlphaStrikeForDrones() {
    final moduleSlots = [
      SlotType.drone,
      SlotType.lightDDSlot,
      SlotType.lightFFSlot,
    ];
    return moduleSlots
        .map(_fitting.fittedModulesForSlot)
        .expand((e) => e)
        .where((d) => d.state != ModuleState.inactive)
        .map(
          (drone) => calculateAlphaStrikeForDrone(
            drone: drone as FittingDrone,
          ),
        )
        .fold<double>(0.0, (previousValue, itemDps) => previousValue + itemDps);
  }

  double calculateDpsForDrone({
    required FittingDrone drone,
  }) {
    final multiplier = getValueForItem(
        attribute: EveEchoesAttribute.fighterNumberLimit, item: drone);
    return drone.fitting.calculateTotalDps() * max(multiplier, 1);
  }

  double calculateAlphaStrikeForDrone({
    required FittingDrone drone,
  }) {
    final multiplier = getValueForItem(
        attribute: EveEchoesAttribute.fighterNumberLimit, item: drone);
    return drone.fitting.calculateTotalAlphaStrike() * max(multiplier, 1);
  }

  double calculateMiningYeildForDrone({
    required FittingDrone drone,
  }) {
    final multiplier = getValueForItem(
        attribute: EveEchoesAttribute.fighterNumberLimit, item: drone);
    return drone.fitting.calculateTotalMiningYeild() * max(multiplier, 1);
  }

  double calculateTotalMiningYeildForDrones() {
    return _fitting
        .fittedModulesForSlot(SlotType.drone)
        .where((d) => d.state != ModuleState.inactive)
        .map(
          (drone) => calculateMiningYeildForDrone(
            drone: drone as FittingDrone,
          ),
        )
        .fold<double>(
            0.0, (previousValue, itemYield) => previousValue + itemYield);
  }

  double calculateTotalMiningYeildPerMinuteForDrone({
    required FittingDrone drone,
  }) =>
      drone.fitting.calculateTotalMiningYeildPerMinute();

  double calculateTotalMiningYeildPerMinuteForDrones() => _fitting
      .fittedModulesForSlot(SlotType.drone)
      .where((d) => d.state != ModuleState.inactive)
      .map(
        (drone) => calculateTotalMiningYeildPerMinuteForDrone(
          drone: drone as FittingDrone,
        ),
      )
      .fold<double>(0.0, (previousValue, itemYpm) => previousValue + itemYpm);

  ///
  /// Get Attribute Value
  ///

  double getValueForShip({
    required EveEchoesAttribute attribute,
  }) =>
      getValueForItem(
        item: ship,
        attribute: attribute,
      );

  double _getValueForShipWithAttributeId({
    required int attributeId,
  }) =>
      _attributeCalculatorService.getValueForItemWithAttributeId(
        attributeId: attributeId,
        item: ship,
      );

  ///
  /// Getting values for characters, the base values come from a special
  /// item numbered 93000000000 - 93000400002 but I guess for EE there is
  /// really only one, and these are duplicated? (TBC)
  double getValueForCharacter({
    required EveEchoesAttribute attribute,
  }) =>
      getValueForItem(
        attribute: attribute,
        item: _characterItem,
      );

  bool fitItem(
    FittingModule module, {
    required SlotType slot,
    required int index,
    bool notify = true,
    ModuleState state = ModuleState.active,
  }) {
    var fittedModule = (module).copyWith(
      slot: slot,
      index: index,
    );

    if (!canFitModule(module: fittedModule, slot: slot)) return false;

    _fitting[slot]![index] = fittedModule.copyWith(
      state: _canActivateModule(fittedModule) ? state : ModuleState.inactive,
    );

    loadout.fitItem(_fitting[slot]![index]);

    if (notify) {
      _updateFitting();
    }

    return true;
  }

  void fitItemIntoAll(
    FittingModule module, {
    required SlotType slot,
    bool notify = true,
  }) {
    final slotList = _fitting[slot] ?? [];
    slotList.forEachIndexed(
      (index, _) => fitItem(
        module,
        slot: slot,
        index: index,
        notify: false,
      ),
    );

    if (notify) {
      _updateFitting();
    }
  }

  // FUTURENOTE: This would be better in another spot
  int numSlotsForType(SlotType slotType) {
    final EveEchoesAttribute numSlotAttr;
    switch (slotType) {
      case SlotType.high:
        numSlotAttr = EveEchoesAttribute.highSlotCount;
        break;
      case SlotType.mid:
        numSlotAttr = EveEchoesAttribute.midSlotCount;
        break;
      case SlotType.low:
        numSlotAttr = EveEchoesAttribute.lowSlotCount;
        break;
      case SlotType.combatRig:
        numSlotAttr = EveEchoesAttribute.combatRigSlotCount;
        break;
      case SlotType.engineeringRig:
        numSlotAttr = EveEchoesAttribute.engineeringRigSlotCount;
        break;
      case SlotType.drone:
        numSlotAttr = EveEchoesAttribute.droneBayCount;
        break;
      case SlotType.nanocore:
        // TODO: HACK: This is stupid, and I don't understand why this isn't in the data
        // but lets be honest - NetEase hates me and wants me to cry T-T
        // We are just going to feed back the same number we had - because
        // AS OF RIGHT NOW THIS DOES NOT CHANGE
        numSlotAttr = EveEchoesAttribute.nanocoreSlotCount;
        return loadout.nanocoreSlots.maxSlots;
      case SlotType.lightFFSlot:
        numSlotAttr = EveEchoesAttribute.lightFFSlot;
        break;
      case SlotType.lightDDSlot:
        numSlotAttr = EveEchoesAttribute.lightDDSlot;
        break;
      case SlotType.hangarRigSlots:
        numSlotAttr = EveEchoesAttribute.hangarRigSlots;
        break;
    }

    return getValueForShip(attribute: numSlotAttr).toInt();
  }

  void _updateFittingLoadout() {
    // FUTURENOTE: This is a stop gap for now - as it would be better that
    // the app does not rely on the static numbering at all!
    final updatedLoadout = ShipLoadoutDefinition(
      numHighSlots: numSlotsForType(SlotType.high),
      numMidSlots: numSlotsForType(SlotType.mid),
      numLowSlots: numSlotsForType(SlotType.low),
      numDroneSlots: numSlotsForType(SlotType.drone),
      numCombatRigSlots: numSlotsForType(SlotType.combatRig),
      numEngineeringRigSlots: numSlotsForType(SlotType.engineeringRig),
      numNanocoreSlots: numSlotsForType(SlotType.nanocore),
      numLightFrigatesSlots: numSlotsForType(SlotType.lightFFSlot),
      numLightDestroyersSlots: numSlotsForType(SlotType.lightDDSlot),
      numHangarRigSlots: numSlotsForType(SlotType.hangarRigSlots),
    );

    _fitting.updateLoadout(updatedLoadout);
    loadout.updateSlotDefinition(updatedLoadout);
  }

  void _updateFitting() => _attributeCalculatorService
      .updateItems(allFittedModules: _fitting.allFittedModules)
      .then((_) => _updateFittingLoadout())
      .then((_) => notifyListeners());

  void updateLoadout() {
    _fitting.allFittedModules.forEach(loadout.fitItem);
    _updateFitting();
  }

  Future<String> printFitting(
    LocalisationRepository localisationRepository,
    ItemRepository itemRepository,
  ) async {
    final items = _fitting.allFittedModules;

    // Need to work out how best to incorporate Rig Integrator counts here
    final itemsGrouped = groupBy<FittingModule, int>(items, (e) => e.groupKey);
    final shipName = localisationRepository.getLocalisedNameForItem(ship.item);

    final strings = await Future.wait(itemsGrouped.entries.map((itemKvp) async {
      final module = items.firstWhereOrNull(
        (e) => e.groupKey == itemKvp.key,
      );

      if (module == null) return '';

      var itemName = localisationRepository.getLocalisedNameForItem(
        module.item,
      );

      if (module is FittingNanocore) {
        if (module.mainAttribute.selectedModifier != null) {
          final modifier =
              await module.mainAttribute.selectedModifier!.modifierName(
            localisation: localisationRepository,
            itemRepository: itemRepository,
          );
          itemName += '\n\t$modifier';
        }

        final modifiers = module.trainableAttributes
            .where((e) => e.selectedModifier != null)
            .map((e) => e.selectedModifier as ItemModifier);

        for (final modifier in modifiers) {
          final modifierName = await modifier.modifierName(
            localisation: localisationRepository,
            itemRepository: itemRepository,
          );
          itemName += '\n\t$modifierName';
        }
      }

      if (module is FittingRigIntegrator) {
        final names = module.integratedRigs
            .map((e) => e.item)
            .map(localisationRepository.getLocalisedNameForItem);

        itemName += ':\n\t${names.join('\n\t')}';
      }

      return '${itemKvp.value.length}x $itemName';
    }));

    final fittingString = strings.join('\n');

    return '$name\n[$shipName]\n\n$fittingString';
  }

  ///
  /// Forward calls for now, as we refactor
  double getValueForItem({
    required EveEchoesAttribute attribute,
    required FittingItem item,
  }) =>
      _attributeCalculatorService.getValueForItem(
        attribute: attribute,
        item: item,
      );

  Future<void> updateAttributes({
    List<FittingSkill> skills = const [],
  }) async {
    await _attributeCalculatorService
        .setup(
          skills: skills,
          ship: ship,
          allFittedModules: _fitting.allFittedModules,
        )
        .then((value) => notifyListeners());
  }

  void updateNihilusModifiers(List<NihilusSpaceModifier> modifiers) {
    _attributeCalculatorService
        .updateNihilusModifiers(modifiers: modifiers)
        .then((value) => notifyListeners());
  }

  Future<CapacitorSimulationResults> capacitorSimulation() =>
      capacitorSimulator.simulate(
        itemRepository: _itemRepository,
        allFittedModules: _fitting.allFittedModules,
      );

  double getValueForSlot({
    required EveEchoesAttribute attribute,
    required SlotType slot,
    required int index,
  }) {
    return getValueForItem(
      item: _fitting[slot]![index],
      attribute: attribute,
    );
  }

  Future<double> calculateDpsForSlotIndex({
    required SlotType slot,
    required int index,
  }) async {
    return calculateDpsForItem(
      item: _fitting[slot]![index],
    );
  }

  Future<void> updateSkills({List<LearnedSkill> skills = const []}) async {
    final fittingSkills =
        await _itemRepository.fittingSkillsFromLearned(skills);
    await updateAttributes(skills: fittingSkills.toList());
  }

  void setShipMode({required bool enabled}) {
    ship.setShipModeEnabled(enabled);

    _attributeCalculatorService
        .updateItems(allFittedModules: _fitting.allFittedModules)
        .then((_) => notifyListeners());
  }

  void setModuleState(
    ModuleState newState, {
    required SlotType slot,
    required int index,
  }) {
    final module = _fitting[slot]![index];
    if (newState != ModuleState.inactive && !_canActivateModule(module)) {
      // Check it can be overloaded/activated
      final activatedGroup = _fitting.allFittedModules.where(
        (m) => m.state != ModuleState.inactive && m.groupId == module.groupId,
      );
      for (var m in activatedGroup) {
        _fitting[m.slot]![m.index] = m.copyWith(
          state: ModuleState.inactive,
        );
      }
    }

    _fitting[module.slot]![module.index] = module.copyWith(
      state: newState,
    );
    loadout.fitItem(_fitting[module.slot]![module.index]);

    _attributeCalculatorService
        .updateItems(allFittedModules: _fitting.allFittedModules)
        .then((_) => notifyListeners());
  }

  bool canFitModule({required FittingModule module, required SlotType? slot}) {
    if (module == FittingModule.empty) return true;

    // Check for moduleCanFitAttributeID
    final canFitAttributeId = module.baseAttributes.firstWhereOrNull(
        (a) => a.id == EveEchoesAttribute.moduleCanFitAttributeID.attributeId);

    if (canFitAttributeId != null) {
      final canFit = _getValueForShipWithAttributeId(
        attributeId: canFitAttributeId.baseValue.toInt(),
      );

      if (canFit == 0.0) return false;
    }

    // check module size
    // only drones for now, as there is no UI to fit others
    if (module is FittingDrone) {
      var moduleSize = module.baseAttributes
              .firstWhereOrNull(
                  (a) => a.id == EveEchoesAttribute.moduleSize.attributeId)
              ?.baseValue ??
          double.maxFinite;
      var droneBandwidth =
          getValueForShip(attribute: EveEchoesAttribute.droneBandwidth);

      return moduleSize <= droneBandwidth;
    }

    final maxGroupActive = module.baseAttributes
            .firstWhereOrNull(
                (a) => a.id == EveEchoesAttribute.maxGroupFitted.attributeId)
            ?.baseValue ??
        double.maxFinite;

    final fittedModulesInGroup = _fitting.allFittedModules.where(
      (m) => m.groupId == module.groupId && !m.inSameSlot(module),
    );

    return fittedModulesInGroup.length < maxGroupActive.toInt();
  }

  bool _canActivateModule(FittingModule module) {
    if (module == FittingModule.empty) return false;

    final maxGroupActive = module.baseAttributes
            .firstWhereOrNull(
                (a) => a.id == EveEchoesAttribute.maxGroupActive.attributeId)
            ?.baseValue ??
        double.maxFinite;

    final activeModulesInGroup = _fitting.allFittedModules.where(
      (m) =>
          m.groupId == module.groupId &&
          m.state != ModuleState.inactive &&
          !m.inSameSlot(module),
    );

    return activeModulesInGroup.length < maxGroupActive.toInt();
  }
}
