// lib/widgets/ui.dart — общие элементы интерфейса и анимации.
import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme.dart';

/// Появление: проявление + сдвиг снизу. Проигрывается один раз.
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final double offsetY;

  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero, this.offsetY = 0.08});

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: kMedium);
  late final Animation<double> _curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween(begin: Offset(0, widget.offsetY), end: Offset.zero).animate(_curve);

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _curve, child: SlideTransition(position: _slide, child: widget.child));
}

/// Появление нового сообщения: место в списке раскрывается, пузырь
/// выезжает снизу со своей стороны и проявляется.
class MessageAppear extends StatefulWidget {
  final Widget child;
  final bool animate;
  final bool fromRight;

  const MessageAppear({super.key, required this.child, required this.animate, required this.fromRight});

  @override
  State<MessageAppear> createState() => _MessageAppearState();
}

class _MessageAppearState extends State<MessageAppear> with SingleTickerProviderStateMixin {
  AnimationController? _c;
  late Animation<double> _curve;
  late Animation<Offset> _slide;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
      _c = c;
      _curve = CurvedAnimation(parent: c, curve: Curves.easeOutCubic);
      _slide = Tween(begin: Offset(widget.fromRight ? 0.08 : -0.08, 0.35), end: Offset.zero).animate(_curve);
      _scale = Tween(begin: 0.94, end: 1.0).animate(_curve);
      c.forward();
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_c == null) return widget.child;
    return SizeTransition(
      sizeFactor: _curve,
      axisAlignment: -1,
      child: FadeTransition(
        opacity: _curve,
        child: SlideTransition(
          position: _slide,
          child: ScaleTransition(
            scale: _scale,
            alignment: widget.fromRight ? Alignment.bottomRight : Alignment.bottomLeft,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Три пульсирующие точки («печатает»).
class TypingDots extends StatefulWidget {
  final Color color;
  const TypingDots({super.key, this.color = AppColors.accent});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final t = ((_c.value - i * 0.2) % 1.0);
          final v = t < 0.5 ? t * 2 : (1 - t) * 2;
          return Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: 0.35 + 0.65 * v),
              shape: BoxShape.circle,
            ),
          );
        }),
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  final String name;
  final Color color;
  final double size;

  const Avatar({super.key, required this.name, required this.color, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        name.isNotEmpty ? name.characters.first.toUpperCase() : '?',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: size * 0.42),
      ),
    );
  }
}

/// Кнопка с индикатором загрузки внутри.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;

  const PrimaryButton({super.key, required this.label, this.onPressed, this.loading = false, this.icon});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: loading ? null : onPressed,
      child: AnimatedSwitcher(
        duration: kFast,
        child: loading
            ? const SizedBox(
                key: ValueKey('l'), width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
            : Row(key: const ValueKey('t'), mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
                Text(label),
              ]),
      ),
    );
  }
}

/// Группа строк в карточке (настройки, списки).
class Group extends StatelessWidget {
  final String? title;
  final List<Widget> children;

  const Group({super.key, this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title!.toUpperCase(),
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.6)),
          ),
        Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(indent: 56),
              children[i],
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Карточка-контейнер.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(20)});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(20)),
        child: child,
      );
}

/// Центрированная колонка ограниченной ширины (удобно на ПК).
class NarrowBody extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const NarrowBody({super.key, required this.child, this.maxWidth = 440});

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
        ),
      );
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? const Color(0xFF5A1D1D) : null,
      duration: const Duration(seconds: 3),
    ));
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? body,
  required String action,
  bool danger = false,
}) async {
  final s = S.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body, style: const TextStyle(color: AppColors.muted, height: 1.4)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            backgroundColor: danger ? AppColors.danger : null,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Нижнее меню действий.
class SheetAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const SheetAction(this.icon, this.label, this.onTap, {this.danger = false});
}

Future<void> showActions(BuildContext context, List<SheetAction> actions) {
  return showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final a in actions)
          ListTile(
            leading: Icon(a.icon, color: a.danger ? AppColors.danger : null),
            title: Text(a.label, style: TextStyle(color: a.danger ? AppColors.danger : null)),
            onTap: () {
              Navigator.pop(ctx);
              a.onTap();
            },
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
}

/// Логотип: замок в скруглённом квадрате.
class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 64});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4C8DFF), Color(0xFF2F5FD0)],
        ),
      ),
      child: Icon(Icons.lock_rounded, color: Colors.white, size: size * 0.5),
    );
  }
}
