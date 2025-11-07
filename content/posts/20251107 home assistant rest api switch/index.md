---
author: ["Ivan Fedotov"]
title: "Making Any REST Resource Work as a Switch in Home Assistant"
slug: home-assistant-rest-api-switch
date: "2025-11-07"
description: "Turning any REST API resource with binary state into a switch in Home Assistant using RESTful Command and Template integrations"
summary: "Turning any REST API resource with binary state into a switch in Home Assistant using RESTful Command and Template integrations"
---

I've recently added Home Assistant to my homelab. While looking for things to automate I
stumbled upon an interesting problem for which I could not find any existing solutions.
So I came up with my own :)

## A bit of backstory

My home is protected by a private security company. They provide a bloated iOS app to arm
and disarm the system. You know the type: slow, packed with useless features, and
absolutely no way to automate anything. It hurt my soul every time I had to use it.

So I wanted to do it better. I wanted to avoid using an app altogether and use iOS widget
or control instead. Home Assistant's companion app can convert a switch entity into a button
in iOS Control Center, which is exactly what I wanted. All I needed was to find a way to manage
REST API service from a switch in HA.

The googling failed me miserably, I could not find anything even remotely close to what I
needed. So it was time for my own brain to shine ~and take over the world~!

<!-- markdownlint-disable-next-line MD013 -->
{{< figure src="./keep-calm.png" alt="Pinky and the Brain" align=center title="Yes, I'm that old" attr="Source: [Know Your Meme](https://knowyourmeme.com/photos/409219-keep-calm-and-carry-on)" >}}

## Step 1. Implement API calls

With the help of web version of the mobile app and browser dev tools, I got 2 REST API
requests for my needs: GET to obtain the current system state and POST to arm or disarm
the system.

> [!WARNING] Disclaimer
> Reverse engineering APIs can be illegal and might break your provider’s terms of
> service. Proceed at your own risk ;)

I should add that POST request takes around 2 seconds to complete and around 10 more
seconds for the system to actually change its state. This will lead to additional tweaking
later.

Home Assistant has [RESTful Command](https://www.home-assistant.io/integrations/rest_command/)
integration built-in. To use it, simply define your requests in `configuration.yaml` (UI
editing is not available at the time of writing) like this:

```yaml
rest_command:
  security_get_state:
    url: "https://security.com/api/object/1337/"
    method: GET
    headers:
      authorization: !secret security_auth_header # Place your secret in secrets.yaml
      accept: "application/json"
    content_type: 'application/json; charset=utf-8'
    timeout: 2
  security_set_state:
    url: "https://security.com/api/object/1337/arm"
    method: POST
    headers:
      authorization: !secret delta_auth_header
      accept: "application/json"
    payload: '{"state":"{{ state }}"}'
    content_type: 'application/json; charset=utf-8'
    timeout: 20
```

Verify that your commands work by calling `rest_command.<command_name>` in
"Developer tools" -> "Actions".

> [!NOTE]
> If your API is weird or REST just won’t cut it, you can swap in
> [Shell Command](https://www.home-assistant.io/integrations/shell_command/) instead and unleash
> the full power of curl or even python.

## Step 2. Create binary sensor

You might be wondering why we need a binary sensor at all. Can't we just create a switch
that calls the REST commands directly? Well, we could, but we wouldn't have any feedback
about the current state of the system. The switch would just optimistically assume that
the system changed its state after calling the command. Binary sensor acts as a monitoring
device that closely tracks the actual state of the security system. And the switch is used
to change that state with feedback from the sensor.

Binary sensor, as the name suggests, can have only two states: "on" and "off". In our case,
"on" means the system is disarmed (open) and "off" means it is armed (closed). That's just
how `device_class: lock` works in Home Assistant. You can choose another device class if
it makes more sense.

Here is the initial implementation of the binary sensor using
[Template](https://www.home-assistant.io/integrations/template/#binary-sensor) integration:

```yaml
template:
  - triggers:
      # run actions every 10 minutes
      - trigger: time_pattern
        minutes: /10
    action:
      # execute API call to get the current state, store response in a variable
      - action: rest_command.security_get_state
        response_variable: security_response

    binary_sensor:
      - name: "House security"
        default_entity_id: binary_sensor.arm_home
        device_class: lock
        # state template gets rendered each time actions are finished executing
        # "True" if system is disarmed (open) and "False" if armed (closed)
        # if response HTTP status is not 200, state will be set to undefined
        state: >
          {%- if security_response['status'] == 200 -%}
            {{- security_response['content']['status'] == "open" -}}
          {% endif -%}
```

Now we have a virtual device in Home Assistant that we can reference to get the current
state of the system. The next step is to create a switch to change it.

## Step 3. Add template switch

Unlike binary sensor with triggers, switch can be created via web UI. I prefer using UI
whenever possible, because it's easier to maintain and completions are really helpful.
Go to "Settings" -> "Devices & Services" -> "Helpers" and click on "Create helper". Choose
"Template" then "Switch". Give it a name, and proceed to defining its state template:

```jinja
{{ is_state('binary_sensor.arm_home', 'off') }}
```

Then define "Actions on turn on":

1. Call REST command to arm the system

    ```yaml
    action: rest_command.security_set_state
    data:
      state: "on"
    metadata: {}
    ```

2. Wait until the system is armed (binary sensor is "off"), but give up after 30 seconds

    ```yaml
    repeat:
      count: 15
      sequence:
        - delay:
            hours: 0
            milliseconds: 0
            minutes: 0
            seconds: 2
        - condition: state
          entity_id: binary_sensor.arm_home
          state: "off"
        - stop: success
    ```

And, finally, define "Actions on turn off":

1. Call REST command to disarm the system

    ```yaml
    action: rest_command.security_set_state
    data:
      state: "off"
    metadata: {}
    ```

2. Wait until the system is disarmed (binary sensor is "on")

    ```yaml
    repeat:
      count: 15
      sequence:
        - delay:
            hours: 0
            milliseconds: 0
            minutes: 0
            seconds: 2
        - condition: state
          entity_id: binary_sensor.arm_home
          state: "on"
        - stop: success
    ```

The delay means that the switch will only update when the binary sensor reflects the new state.
That is the desired effect. I want to have a feedback that the system successfully changed
its state. If that's not what you want, you can remove the wait actions and set the switch
as optimistic, but I will not cover that here.

Here's how the final switch configuration looks like in UI:
<!-- markdownlint-disable-next-line MD013 -->
{{< figure src="./switch-ui-config.png" alt="complete switch configuration in UI" align=center title="Complete switch configuration in UI" >}}

## Step 4. Additional logic for the binary sensor

Now the tricky part. If you were to click on the switch, for instance, to arm the system,
the switch would first turn on, then turn off after 30 seconds, and then finally turn on
again when the binary sensor updates its state via the periodic polling (which may take up
to 10 minutes). One way to mitigate this is to reduce the polling interval, but that would
increase the load on the API and may lead to rate limiting. There is much better way to
handle this.

We can modify the binary sensor to do additional polling when the state change request is
made. In that case, we can poll the API multiple times with a small delay until the state
actually changes. This way, the binary sensor will reflect the new state after
a state change request much faster.

Here is the updated binary sensor implementation:

```yaml
template:
  - triggers:
      - trigger: time_pattern
        minutes: /10
      # this trigger runs actions when rest_command.security_set_state 
      # is called indicating that the system state is changing
      - trigger: event
        event_type: call_service
        event_data:
          domain: rest_command
          service: security_set_state
        id: arm_state
    action:
      # if actions are triggered by state change request,
      # poll the API until the state changes
      - if:
          - condition: trigger
            id: [arm_state]
        then:
          - repeat:
              count: 7
              sequence:
                - delay:
                    hours: 0
                    minutes: 0
                    seconds: 5
                - action: rest_command.security_get_state
                  response_variable: security_response
                # this condition template is the same
                # as the binary sensor state template
                - condition: template
                  value_template: >
                    {%- if security_response['status'] == 200 -%}
                      {{- security_response['content']['status'] == "open" -}}
                    {% endif -%}
                - stop: success
        # if actions are triggered by time pattern, just poll the API once
        else:
          - action: rest_command.security_get_state
            response_variable: security_response

    binary_sensor:
      - name: "House security"
        default_entity_id: binary_sensor.arm_home
        device_class: lock
        state: >
          {%- if security_response['status'] == 200 -%}
            {{- security_response['content']['status'] == "open" -}}
          {% endif -%}
```

And that's it! We now have a fully functional switch in Home Assistant that can arm and disarm
the security system via REST API calls, with proper state monitoring and feedback. Make
sure to set all the delays and timeouts according to your specific API behavior for the
best experience.

## Wrapping Up

Even though the implementation ended up being a bit more complex than I initially expected,
I learned a lot about Home Assistant's internals and I'm pleased with the final result.

If you’ve got a similar setup, or found a better way, please send me an email!
