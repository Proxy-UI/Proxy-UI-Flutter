import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

/// Utility class for displaying toast messages using toastification package.
class ToastUtils {
  static const Duration shortDuration = Duration(seconds: 2);
  static const Duration normalDuration = Duration(seconds: 3);

  static void showSuccess(String message, {String? title}) {
    toastification.show(
      type: ToastificationType.success,
      style: ToastificationStyle.flatColored,
      title: title != null ? Text(title) : null,
      description: Text(message),
      autoCloseDuration: shortDuration,
      alignment: Alignment.bottomCenter,
    );
  }

  static void showError(String message, {String? title}) {
    toastification.show(
      type: ToastificationType.error,
      style: ToastificationStyle.flatColored,
      title: title != null ? Text(title) : null,
      description: Text(message),
      autoCloseDuration: normalDuration,
      alignment: Alignment.bottomCenter,
    );
  }

  static void showInfo(String message, {String? title}) {
    toastification.show(
      type: ToastificationType.info,
      style: ToastificationStyle.flatColored,
      title: title != null ? Text(title) : null,
      description: Text(message),
      autoCloseDuration: shortDuration,
      alignment: Alignment.bottomCenter,
    );
  }

  static void showWarning(String message, {String? title}) {
    toastification.show(
      type: ToastificationType.warning,
      style: ToastificationStyle.flatColored,
      title: title != null ? Text(title) : null,
      description: Text(message),
      autoCloseDuration: normalDuration,
      alignment: Alignment.bottomCenter,
    );
  }
}
