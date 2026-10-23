# Code Style Guidelines

No hardcoded size values. All sizes must come from default tokens or ratio-based sizing. Do not set size/height/width/margin literals, and do not instantiate SizedBox/EdgeInsets/Constraints with literal size values.

No StatefulWidget. All widgets must be stateless, with state managed by GetX.

When using GetX, do not use `Get.find()` outside of the controller and bindings. If possible, do not `Get.put(permanent: true)` in the controller, and instead use `Get.lazyPut()` in the bindings.

No named routes. No `Get.toNamed()` or `Get.offNamed()`. Use `Get.to()` or `Get.off()` instead.

Do not create any GetX service or controller with new keyword. Use `Get.put()` or `Get.lazyPut()` instead. 

Prefer using Dart Native Assets Hooks , instead of using Platform Channels or configure FFI manually. 

# Documentation Guidelines

Only add documentation required or requested by the maintainer.

All documentation goes in `docs/` in Markdown. README and CHANGELOG follow their conventional locations.

Documentation must be clear and concise, with no redundant or irrelevant content.

# Git Commit Guidelines

Do not commit any code , add into the repository or commit any pull requests, except the maintainer requires it.

# Annotations

Annotations must be concise and unambiguous, conveying only what is necessary. Do not add redundant, irrelevant, or vague annotations.

- Functions: briefly describe what the function does, its parameters, and its return value.
- Classes/structs: briefly describe what it represents and its purpose.
- Omit annotations when the code is already self-explanatory.
- If unsure whether an annotation is needed, ask the maintainer first.

# Testing and Quality Assurance

No tests should be written or added to the production codebase. All tests should be written into the "test/" folder.

use `flutter analyze` to check for any errors or warnings in the code. If any errors or warnings are found, you must fix them before proceeding.

If you add new features or make changes to existing code, you must ensure that the code is properly tested. This includes writing unit tests, integration tests, and any other relevant tests to cover the new functionality.

When All changes complete, you must use `flutter test` to run all the tests to ensure that everything is working as expected. If any tests fail, you must fix the issues before proceeding.

use `dart format` at last.