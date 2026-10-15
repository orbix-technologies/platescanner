# Ethiopian plate format (provisional)

Fields: **service code** (1 public transport, 2 private, 3 commercial,
4 government, 5 NGO; CD, AU, UN, POLICE), **region** (Latin + Amharic
abbreviation), **serial** (5 digits, newer plates with a Latin letter prefix).

Values in `lib/src/parsing/ethiopian_region.dart` and
`plate_service_type.dart` come from general knowledge, not a sourced regulation.

Open questions:

- [ ] Confirm code-to-colour mapping and the full special-plate list.
- [ ] Confirm Latin + Amharic codes for regions created after 2020.
- [ ] Confirm whether every plate carries a Latin region code.
