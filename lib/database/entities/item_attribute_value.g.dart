// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'item_attribute_value.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ItemAttributeValue _$ItemAttributeValueFromJson(Map<String, dynamic> json) =>
    ItemAttributeValue(
      json['attributeId'] as int,
      (json['value'] as num).toDouble(),
      json['itemId'] as int,
    );

Map<String, dynamic> _$ItemAttributeValueToJson(ItemAttributeValue instance) =>
    <String, dynamic>{
      'itemId': instance.itemId,
      'attributeId': instance.attributeId,
      'value': instance.value,
    };
