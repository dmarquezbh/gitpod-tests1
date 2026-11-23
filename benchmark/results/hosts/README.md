# Resultados por host

`benchmark/results/` guarda a medição do host atual (metadados em `../host.json`).
Antes de rodar em outra máquina, copie a pasta atual para cá:

```bash
cd benchmark/results
cp -a . hosts/$(hostname)-$(date +%Y%m%d)/
```

O publish da página (`tools/publish-site.sh`) lê apenas `results/*/summary.csv` e
`results/metrics.csv`; ele não apaga nem move resultados antigos.
