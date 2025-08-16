Here are a few lesson learned from Trio that I plan to adopt in GlucOS:

✅ Low pass filter
  - limit to G7 only?

- Be more aggressive with SMB
  ✅ start SMB at lower glucose
  ✅ Give higher percentage of insulin needs via SMB
  - after I understand the SMB enabling logic in Trio
    - loosen some of our SMB restrictions (must be rising)
    - also issue temp basal when issuing SMB

✅ Decrease sensitivity at high glucose values

- Update Lyumjev curve to 45m peak and 10h dia
  - The literature isn't backing up 45m for max glucose absorption,
    so I'll need to do some experimentation on this

- Remove exercise mode and enable overrides