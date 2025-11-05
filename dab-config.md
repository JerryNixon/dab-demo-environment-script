## dab-config.json
<p>&nbsp;</p>

```mermaid
stateDiagram-v2
direction LR

  classDef empty fill:none,stroke:none
  classDef table stroke:black;
  classDef view stroke:black;
  classDef proc stroke:black;
  classDef phantom stroke:gray,stroke-dasharray:5 5;


  class Actor table
  class Character table
  class Series table
  class Species table
  class Series_Character table
  class Character_Species table
  class Series_Character phantom
  class Character_Species phantom
  state Tables {
    Actor --> Character
    Character --> Actor
    Series_Character --> Series
    Character_Species --> Species
    Series_Character --> Character
    Character_Species --> Character
  }
  class SeriesActors view
  state Views {
    SeriesActors
  }
  class GetSeriesActors proc
  state Procedures {
    GetSeriesActors
  }
```

### Tables
|Entity|Source|Relationships
|-|-|-
|Actor|dbo.Actor|Character
|Character|dbo.Character|Actor, Series, Species
|Series|dbo.Series|Character
|Species|dbo.Species|Character

### Views
|Entity|Source
|-|-
|SeriesActors|dbo.SeriesActors

### Stored Procedures
|Entity|Source
|-|-
|GetSeriesActors |dbo.GetSeriesActors

