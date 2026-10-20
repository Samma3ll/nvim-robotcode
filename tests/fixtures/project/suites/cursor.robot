*** Settings ***
Documentation    Cursor selection integration fixture.

*** Variables ***
${MESSAGE}    default

*** Test Cases ***
First test
    Should Be Equal    ${PARENT_SETUP}    inherited
    Log    first

Literal [x] * ? test
    Should Be Equal    ${PARENT_SETUP}    inherited
    Log Many    ${MESSAGE}    %{ROBOTCODE_NVIM_CHECK=missing}    %{ROBOTCODE_DAP_ONLY=run}

Last test
    Fail    This test must never run when selecting the second test.

*** Keywords ***
Helper keyword
    No Operation
