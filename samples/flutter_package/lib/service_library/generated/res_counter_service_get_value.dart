﻿import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

part 'res_counter_service_get_value.g.dart';

/// An annotation for the code generator to know that this class needs the
/// the star denotes the source file name.
@immutable
@JsonSerializable(nullable: true, explicitToJson: true, anyMap: true)
class ResCounterServiceGetValue {

	ResCounterServiceGetValue({
		this.returnValue,
	});

	@JsonKey(name: "ReturnValue", nullable: false)
	final int returnValue;


	factory ResCounterServiceGetValue.fromJson(Map<dynamic, dynamic> json) => _$ResCounterServiceGetValueFromJson(json);

	Map<String, dynamic> toJson() => _$ResCounterServiceGetValueToJson(this);

}
