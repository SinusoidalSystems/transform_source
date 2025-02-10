# transform_source

This plugin applies a parse transform to specified source code and then saves that source code.
This can be useful if one wants to generate documentation from transformed code.

## edoc

In the long run, we should file two issues for OTP:

1. Make `compile(..., ['P']).` keep the documentation attributes.
2. Provide `edoc` with an option to apply 'P' compilation before creating doc.  
